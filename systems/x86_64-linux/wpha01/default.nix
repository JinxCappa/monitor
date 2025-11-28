{
    lib,
    config,
    pkgs,
    ...
}: let
  toml = lib.importTOML ../../../secrets/crypt.toml;
in
{
  networking.hostName = "wpha01";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  profiles.system = {
    enable = true;
    desktop = {
      enable = true;
      environment = "xfce";
    };
  };

  sops = {
    defaultSopsFile = ./files/sops-nix.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."netbird-setup-key" = {};
  };

  deploy = {
    address = toml.${config.networking.hostName}.address;
    remoteBuild = true;
    user = "nixos";
  };

  services.cloudflare-ssh = {
    enable = true;                                        # Required
    tunnelId = toml.${config.networking.hostName}.tunnel-id;    # Required - tunnel UUID
    hostname = toml.${config.networking.hostName}.cloudflare-hostname;                         # Required - public hostname
    sopsFile = ./files/sops-nix.yaml;                            # Required - path to sops file                                 # Optional (default: false)
  };

}
