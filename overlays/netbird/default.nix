{
  lib,
  inputs,
  ...
}:

final: prev:
{
  inherit inputs;

  netbird = inputs.jinx-pkgs.packages.${prev.system}.netbird;
}
