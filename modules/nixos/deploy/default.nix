{
  config,
  lib,
  ...
}:
with lib;
with lib.aulogix; let
  cfg = config.deploy;
in {
  options.deploy = {
    hostname = mkOpt types.anything null "The hostname of the target machine.";
    address = mkOpt types.anything null "The address of the target machine.";
    sshUser = mkOpt types.anything null "The SSH user to connect as.";
    user = mkOpt types.anything null "The user to activate the system for.";
    remoteBuild = mkOpt types.bool false "The remote build command.";
  };
}