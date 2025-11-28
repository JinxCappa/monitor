{
  lib,
  inputs,
  ...
}:

final: prev:
{
  inherit inputs;

  deploy-rs = inputs.jinx-pkgs.packages.${prev.system}.deploy-rs;
}