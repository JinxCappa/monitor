{
    lib,
    config,
    ...
}: let
  secrets = lib.importTOML ./files/crypt/secrets.toml;
in
{
  networking.hostName = "CHANGEME";

  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  profiles.system = {
    enable = true;
    desktop.enable = true;  # set to false for headless
  };

  sops = {
    defaultSopsFile = ./files/crypt/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."netbird-setup-key" = {};
  };

  deploy = {
    address = secrets.address;
    remoteBuild = true;
    user = "nixos";
  };
}