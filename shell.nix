{pkgs ? import <nixpkgs> {}}: let
  erl = with pkgs; beam.packages.erlang_26;
  ex = erl.elixir_1_16;

  # define packages to install with special handling for OSX
  inputs = [
    ex
    (erl.elixir-ls.override {elixir = ex;})
    pkgs.libyaml
    pkgs.libyaml.dev
  ];

  # define shell startup command
  hooks = ''
    # this allows mix to work on the local directory
    mkdir -p .nix-mix
    mkdir -p .nix-hex
    export MIX_HOME=$PWD/.nix-mix
    export HEX_HOME=$PWD/.nix-hex
    export PATH=$MIX_HOME/bin:$PATH
    export PATH=$HEX_HOME/bin:$PATH
    export LANG=en_US.UTF-8
    export ERL_AFLAGS="-kernel shell_history enabled"
  '';
  #alias pip="PIP_PREFIX='$(pwd)/_build/pip_packages' \pip"
  #export PYTHONPATH="$(pwd)/_build/pip_packages/lib/python3.7/site-packages:$PYTHONPATH"
in
  pkgs.mkShell {
    buildInputs = inputs;
    shellHook = hooks;
  }
