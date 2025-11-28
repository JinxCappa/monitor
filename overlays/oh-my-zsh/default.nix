{
  lib,
  inputs,
  ...
}:

final: prev:
{
  inherit inputs;

  oh-my-zsh = inputs.jinx-pkgs.packages.${prev.system}.oh-my-zsh;
}