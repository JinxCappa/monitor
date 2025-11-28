# System profile module - base configuration with optional desktop features
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.profiles.system;
  toml = lib.importTOML ../../../secrets/crypt.toml;
in
{
  options.profiles.system = {
    enable = mkEnableOption "base system profile (users, SSH, zabbix, netbird)";

    desktop = {
      enable = mkEnableOption "desktop environment (GUI, audio, printing)";
      environment = mkOption {
        type = types.enum [ "lxqt" "xfce" ];
        default = "lxqt";
        description = "Desktop environment to use";
      };
    };

    prometheus = {
      snmp = {
        enable = mkEnableOption "SNMP exporter";
        configurationPath = mkOption {
          type = types.path;
          description = "Path to SNMP exporter configuration file";
        };
      };
      blackbox = {
        enable = mkEnableOption "Blackbox exporter";
        configFile = mkOption {
          type = types.path;
          description = "Path to Blackbox exporter configuration file";
        };
      };
    };

    stateVersion = mkOption {
      type = types.str;
      default = "25.05";
      description = "NixOS state version";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # ============ BASE CONFIGURATION ============
    {
      time.timeZone = lib.mkDefault "US/Eastern";
      i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
      networking.domain = lib.mkDefault toml.domain;
      networking.firewall.enable = lib.mkDefault false;

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          TrustedUserCAKeys = "/etc/ssh/cloudflare_access_ca.pub";
          Macs = [
            "hmac-sha2-256"
            "hmac-sha2-512"
            "hmac-sha2-256-etm@openssh.com"
            "hmac-sha2-512-etm@openssh.com"
          ];
        };
      };

      users = {
        mutableUsers = false;
        users = {
          nixos = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          hashedPassword = toml.password or null;
          openssh.authorizedKeys.keys = toml.ssh-keys;
          shell = pkgs.zsh;
          };
          cloudflared = {
            isSystemUser = true;
            group = "cloudflared";
            home = "/var/lib/cloudflared";
          };
        };
        groups = {
          cloudflared = {
            members = [ "cloudflared" ];
          };
        };
      };

      security.sudo.extraRules = [
        {
          users = [ "nixos" ];
          commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
        }
      ];

      programs.zsh.enable = true;

      environment.systemPackages = with pkgs; [
        htop
        iputils
        curl
        jq
        gitMinimal
        sops
        age
        ssh-to-age
      ];

      nix = {
        nixPath = [ "nixpkgs=flake:nixpkgs" ];
        settings = {
          substituters = toml.nix.substituters;
          trusted-public-keys = toml.nix.trusted-public-keys;
        };
      };

      # NetBird
      services.netbird = {
        clients.wt0 = {
          interface = "wt0";
          port = 51820;
          hardened = false;

          environment = {
            NB_MANAGEMENT_URL = toml.netbird.management_url;
            NB_ADMIN_URL = toml.netbird.management_url;
            NB_HOSTNAME = config.networking.hostName;
          };

          login = {
            enable = true;
            setupKeyFile = config.sops.secrets."netbird-setup-key".path;
            ssh = {
              allowServerSsh = true;
              disableAuth = true;
            };
          };

          autoStart = true;
        };
      };

      system.stateVersion = cfg.stateVersion;

      systemd.services.netbird-wt0 = {
        path = [ pkgs.shadow ];
        serviceConfig.ReadWritePaths = [ "/etc/ssh/ssh_config.d" ];
      };

      services.prometheus.exporters = {
        snmp = mkIf cfg.prometheus.snmp.enable {
          enable = true;
          configurationPath = cfg.prometheus.snmp.configurationPath;
        };
        blackbox = mkIf cfg.prometheus.blackbox.enable {
          enable = true;
          configFile = cfg.prometheus.blackbox.configFile;
        };
      };

      # Sops age key generation
      system.activationScripts.sopsAgeKey = {
        text = ''
          set -euo pipefail

          generate_age_key() {
            local user_home="$1"
            local owner="$2"
            local group="$3"
            local age_dir="$user_home/.config/sops/age"
            local age_keys="$age_dir/keys.txt"

            if [ ! -f "$age_keys" ]; then
              echo "Generating sops age key: /etc/ssh/ssh_host_ed25519_key -> $age_keys"
              mkdir -p "$age_dir"
              TMP_KEYS="$(${pkgs.coreutils}/bin/mktemp)"
              ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > "$TMP_KEYS"
              ${pkgs.coreutils}/bin/install -m 600 -o "$owner" -g "$group" "$TMP_KEYS" "$age_keys"
              rm -f "$TMP_KEYS"
              chown -R "$owner:$group" "$user_home/.config"
              chmod 700 "$age_dir"
            fi
          }

          generate_age_key "/home/nixos" "nixos" "users"
          generate_age_key "/root" "root" "root"
        '';
      };

      # Nightly rebuild service
      systemd.services.repo-nightly = {
        description = "Nightly flake update, bootstrap, and nixos-rebuild switch";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig.Type = "oneshot";

        environment.HOME = "/root";

        path = [
          pkgs.bash
          pkgs.coreutils
          pkgs.diffutils
          pkgs.getent
          pkgs.git
          pkgs.gnugrep
          pkgs.sops
        ];

        script = ''
          set -euo pipefail

          REPO_URL="${toml.repoUrl}"
          FLAKE_HOST="${config.networking.hostName}"
          TMP_DIR="/tmp/repo-nightly"

          rm -rf "$TMP_DIR"
          echo "Cloning into $TMP_DIR"

          ${pkgs.git}/bin/git clone "$REPO_URL" "$TMP_DIR"
          cd "$TMP_DIR"
          ./scripts/bootstrap-git.sh

          echo "Rebuilding system from flake $TMP_DIR#$FLAKE_HOST ..."
          ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
            --flake "$TMP_DIR#$FLAKE_HOST"

          echo "nixos-rebuild switch finished successfully."
          rm -rf "$TMP_DIR"
        '';
      };

      systemd.timers.repo-nightly = {
        description = "Run repo-nightly flake rebuild at midnight";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "00:00";
          Persistent = true;
        };
      };

      environment.etc."ssh/cloudflare_access_ca.pub".text = toml.cloudflared-ca;
    }

    # ============ HEADLESS-SPECIFIC (non-desktop) ============
    (mkIf (!cfg.desktop.enable) {
      boot.loader.grub = {
        efiSupport = true;
        efiInstallAsRemovable = true;
      };
    })

    # ============ DESKTOP-SPECIFIC ============
    (mkIf cfg.desktop.enable {
      # Bootloader
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.kernelPackages = pkgs.linuxPackages_latest;

      # Network Manager
      networking.networkmanager.enable = true;
      users.users.nixos.extraGroups = [ "networkmanager" "wheel" ];
      programs.nm-applet.enable = true;

      i18n.extraLocaleSettings = {
        LC_ADDRESS = "en_US.UTF-8";
        LC_IDENTIFICATION = "en_US.UTF-8";
        LC_MEASUREMENT = "en_US.UTF-8";
        LC_MONETARY = "en_US.UTF-8";
        LC_NAME = "en_US.UTF-8";
        LC_NUMERIC = "en_US.UTF-8";
        LC_PAPER = "en_US.UTF-8";
        LC_TELEPHONE = "en_US.UTF-8";
        LC_TIME = "en_US.UTF-8";
      };

      # X11 + Desktop
      services.xserver.enable = true;
      services.xserver.displayManager.lightdm.enable = true;
      services.xserver.desktopManager.lxqt.enable = cfg.desktop.environment == "lxqt";
      services.xserver.desktopManager.xfce.enable = cfg.desktop.environment == "xfce";
      services.displayManager.autoLogin = {
        enable = true;
        user = "nixos";
      };
      security.pam.services.xscreensaver.enable = true;
      # services.x2goserver.enable = true;

      services.xserver.xkb = {
        layout = "us";
        variant = "";
      };

      # Printing
      services.printing.enable = true;

      # Audio (pipewire)
      services.pulseaudio.enable = false;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };

      systemd.user.services.rustdesk = {
        description = "RustDesk";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          ExecStart = "${pkgs.rustdesk}/bin/rustdesk";
          Restart = "always";
          RestartSec = 2;
        };
      };

      # Desktop apps
      programs.firefox.enable = true;
      nixpkgs.config.allowUnfree = true;

      environment.systemPackages = with pkgs; [
        rustdesk
      ];

      # NetBird UI for desktop
      services.netbird.clients.wt0 = {
        ui.enable = true;
      };
    })
  ]);
}
