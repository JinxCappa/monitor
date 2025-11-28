{
    lib,
    config,
    pkgs,
    ...
}: let
  toml = lib.importTOML ../../../secrets/crypt.toml;
  upstreamRelabelConfig = pkgs.writeText "vmagent-upstream-relabel.yml" ''
    - action: keep
      source_labels: [vm_route]
      regex: upstream
    - action: labeldrop
      regex: vm_route
  '';
  tenantRelabelConfig = pkgs.writeText "vmagent-tenant-relabel.yml" ''
    - action: keep
      source_labels: [vm_route]
      regex: tenant
    - action: labeldrop
      regex: vm_route
  '';
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
    secrets."vmagent/upstream_bearer_token" = {};
    secrets."vmagent/tenant_write_bearer_token" = {};
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
      "-remoteWrite.url=https://metrics.aulogix.com/insert/3/prometheus/api/v1/write"
      "-remoteWrite.bearerTokenFile=%d/upstream_bearer_token"
      "-remoteWrite.bearerTokenFile=%d/tenant_write_bearer_token"
      "-remoteWrite.urlRelabelConfig=${upstreamRelabelConfig}"
      "-remoteWrite.urlRelabelConfig=${tenantRelabelConfig}"
    ];
  };

  systemd.services.vmagent.serviceConfig.LoadCredential = [
    "prometheus.yml:${config.sops.secrets."vmagent/prometheus_yml".path}"
    "upstream_bearer_token:${config.sops.secrets."vmagent/upstream_bearer_token".path}"
    "tenant_write_bearer_token:${config.sops.secrets."vmagent/tenant_write_bearer_token".path}"
  ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
  };

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
        identity = "wpha01-proxy";
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
        identity = "wpha01";
      };
    };
  };

}
