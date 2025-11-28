{
    lib,
    config,
    pkgs,
    ...
}: let
  toml = lib.importTOML ../../../secrets/crypt.toml;
in
{

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
      remotepc.enable = true;
    };
  };

  sops = {
    defaultSopsFile = ./files/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."netbird-setup-key" = {};
    secrets."vmagent/prometheus_yml" = {};
    secrets."vmagent/remote_write_bearer_token" = {};
  };

  deploy = {
    address = toml.${config.networking.hostName}.address;
    remoteBuild = true;
    user = "nixos";
  };

  services.vmagent = {
    enable = true;
    remoteWrite.url = "https://metrics.aulogix.com/insert/2/prometheus/api/v1/write";
    extraArgs = [
      "-promscrape.config=%d/prometheus.yml"
      "-remoteWrite.bearerTokenFile=%d/remote_write_bearer_token"
    ];
  };

  systemd.services.vmagent.serviceConfig.LoadCredential = [
    "prometheus.yml:${config.sops.secrets."vmagent/prometheus_yml".path}"
    "remote_write_bearer_token:${config.sops.secrets."vmagent/remote_write_bearer_token".path}"
  ];

  services.zabbixProxy = {
    enable = true;
    package = pkgs.zabbix80pre.proxy-sqlite;
    server = "monitor.aulogix.com";
    database.type = "sqlite";
    database.createLocally = false;
    settings.StatsAllowedIP = "127.0.0.1";
    tls = {
      enable = true;
      connect = "psk";
      psk = {
        autoGenerate.enable = true;
        identity = "rack01-proxy";
      };
    };
  };

  systemd.services.zabbix-proxy.serviceConfig.LimitNOFILE = 65536;

  services.zabbixAgent2 = {
    enable = true;
    serverActive = "monitor.aulogix.com";
    package = pkgs.zabbix80pre.agent2;
    hostname = "${config.networking.hostName}-proxy";
    extraPackages = [ pkgs.bash ];
    tls = {
      enable = true;
      connect = "psk";
      psk = {
        autoGenerate.enable = true;
        identity = "rack01";
      };
    };
  };

}
