#!/bin/sh
if [[ -z "$1" ]]; then
  echo "Needs a .exs script"
  exit 1
fi
MIX_ENV="bench" mix run $1
