{ pkgs ? import <nixpkgs> {} }:
with pkgs;
let
  # define packages to install with special handling for OSX
  inputs = [
    elixir_1_15
    (elixir-ls.override { elixir = elixir_1_15; })
    libyaml
    libyaml.dev
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

in mkShell {
  buildInputs = inputs;
  shellHook = hooks;
}
