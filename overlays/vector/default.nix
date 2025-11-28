{
  lib,
  inputs,
  ...
}:

final: prev:
{
  inherit inputs;

  vector = inputs.jinx-pkgs.packages.${prev.system}.vector;
}