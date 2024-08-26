{
  description = "Stampede dev environment and pre-push checks";
  # NOTE: enter the environment with `nix develop .#`

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.systems.url = "github:nix-systems/default";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.systems.follows = "systems";

  inputs.git-hooks.url = "github:cachix/git-hooks.nix";
  inputs.git-hooks.inputs.nixpkgs.follows = "nixpkgs";

  outputs = {
    # self,
    # systems,
    nixpkgs,
    flake-utils,
    git-hooks,
    ...
  }:
    flake-utils.lib.eachDefaultSystem
    (
      system: let
        # NOTE: change to true to enable commit checks
        # when disabled, also run "pre-commit uninstall" to disable
        enablePreCommitChecks = true;

        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        systemPackages =
          lib.optionals pkgs.stdenv.isLinux [
            # For ExUnit Notifier on Linux.
            pkgs.libnotify

            # For file_system on Linux.
            pkgs.inotify-tools
          ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            # For ExUnit Notifier on macOS.
            pkgs.terminal-notifier

            # For file_system on macOS.
            pkgs.darwin.apple_sdk.frameworks.CoreFoundation
            pkgs.darwin.apple_sdk.frameworks.CoreServices
          ];

        ########################
        # Erlang/Elixir versions

        erl = with pkgs; beam.packages.erlang_26;
        # # Use graphics-free Erlang. Makes sense but requires full rebuild, as of 10/2024
        # erl = with pkgs; beam_nox.packages.erlang_26;
        ex = erl.elixir_1_16;

        ########################
        # Python versions
        python = pkgs.python312;
        mkPyPkg = name: python.withPackages (ps: [(builtins.getAttr name ps)]);

        ########################
        # Git pre-push checks
        pc-hooks = git-hooks.lib.${system}.run {
          # only run on push and directly calling `pre-commit` in the shell
          default_stages = ["manual" "push" "pre-merge-commit"];
          src = ./.;
          hooks = let
            enable_on_commit = {
              enable = true;
              stages = ["manual" "push" "pre-merge-commit" "pre-commit"];
            };
          in {
            check-merge-conflicts.enable = true;
            check-vcs-permalinks.enable = true;
            editorconfig-checker = enable_on_commit;
            # TODO: tagref

            alejandra = enable_on_commit;
            flake-checker.enable = true;

            # NOTE: disable to reduce deps
            actionlint = enable_on_commit;
            yamlfmt = enable_on_commit;
            convco = {
              enable = true;
              stages = ["commit-msg"];
            };
            deadnix.enable = true;

            dialyzer = {
              enable = true;
              package = ex;
            };
            custom-mix-test = {
              enable = true;
              name = "mix-test";
              entry = "${ex}/bin/mix test";
              files = "\\.exs?$";
              types = ["text"];
              pass_filenames = false;
              require_serial = true;
            };
            custom-mix-format =
              enable_on_commit
              // {
                name = "mix-format";
                entry = "${ex}/bin/mix format --check-formatted";
                files = "\\.exs?$";
                types = ["text"];
                pass_filenames = false;
                require_serial = true;
              };

            mypy =
              enable_on_commit
              // {
                package = mkPyPkg "mypy";
              };
            black =
              enable_on_commit
              // {
                package = mkPyPkg "black";
              };
          };
        };
      in {
        #####################
        # FLAKE OUTPUTS
        checks.default = pc-hooks;
        devShells.default = let
          #####################
          # DEV SHELL WITH PRE-PUSH HOOKS
          inputs =
            [
              ex
              (erl.elixir-ls.override {elixir = ex;})

              pkgs.libyaml
              pkgs.libyaml.dev

              python
              (mkPyPkg "python-lsp-server")
              (mkPyPkg "pylsp-mypy")
              (mkPyPkg "python-lsp-black")

              pkgs.nixd
            ]
            ++ pc-hooks.enabledPackages
            ++ systemPackages;

          # define shell startup command
          sh-hook =
            ''
              export FLAKE_PYTHON="${python}/bin/python3"

              # this allows mix to work on the local directory
              mkdir -p .nix-mix
              mkdir -p .nix-hex
              export MIX_HOME=$PWD/.nix-mix
              export HEX_HOME=$PWD/.nix-hex
              export PATH=$MIX_HOME/bin:$PATH
              export PATH=$HEX_HOME/bin:$PATH
              export LANG=en_US.UTF-8
              export ERL_AFLAGS="-kernel shell_history enabled"
            ''
            + lib.optionalString enablePreCommitChecks pc-hooks.shellHook;
        in
          pkgs.mkShell {
            buildInputs = inputs;
            shellHook = sh-hook;
          };
      }
    );
}
