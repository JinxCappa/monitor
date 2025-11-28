{
    config,
    # Snowfall Lib provides a customized `lib` instance with access to your flake's library
    # as well as the libraries available from your flake's inputs.
    lib,
    # An instance of `pkgs` with your overlays and packages applied is also available.
    pkgs,
    # You also have access to your flake's inputs.
    inputs,
    ...
}: let
  toml = lib.importTOML ../../../../../secrets/crypt.toml; 
in
{  

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  time.timeZone = lib.mkForce "US/Eastern";
  i18n.defaultLocale = lib.mkForce "en_US.UTF-8";
  networking.domain = lib.mkForce toml.domain;
  networking.firewall.enable = lib.mkForce false;
  networking.networkmanager.enable = true;

  # Enable network manager applet
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

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the LXQT Desktop Environment.
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.lxqt.enable = true;

  security.pam.services.xscreensaver.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  users = {
    mutableUsers = false;
    users = {
      nixos = {
        isNormalUser = true;
        extraGroups = [ "networkmanager" "wheel" ];
        hashedPassword = toml.password;
        openssh = {
          authorizedKeys = {
            keys = toml.ssh-keys;
          };
        };
        shell = pkgs.zsh;       
      };
    };
  };

  security.sudo.extraRules = [
    { 
      users = [ "nixos" ];
      commands = [ { command = "ALL"; options = ["NOPASSWD"]; } ];
    }
  ];

  programs.zsh.enable = true;

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    iputils    # ping
    curl
    jq
    htop
    gitMinimal
    sops
    age
    netbird-ui
    rustdesk
  ];

  nix = {
    nixPath = [ "nixpkgs=flake:nixpkgs" ];
    settings = {
      substituters = toml.nix.substituters;
      trusted-public-keys = toml.nix.trusted-public-keys;
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  system.activationScripts.sopsAgeKey = {
    text = ''
      set -euo pipefail

      USER_HOME="/home/nixos"
      AGE_DIR="$USER_HOME/.config/sops/age"
      AGE_KEYS="$AGE_DIR/keys.txt"

      if [ ! -f "$AGE_KEYS" ]; then
        echo "Generating sops age keys for /etc/ssh/ssh_host_ed25519_key -> $AGE_KEYS"

        # Ensure directory exists
        mkdir -p "$AGE_DIR"

        # Generate age key material from host ssh ed25519 key
        TMP_KEYS="$(${pkgs.coreutils}/bin/mktemp)"
        ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > "$TMP_KEYS"

        # Install with requested permissions (0700) and proper ownership
        ${pkgs.coreutils}/bin/install -m 700 -o nixos -g users "$TMP_KEYS" "$AGE_KEYS"
        rm -f "$TMP_KEYS"

        # Ensure directory is also private
        chown -R nixos:users "$USER_HOME/.config"
        chmod 700 "$AGE_DIR"

        echo "sops age keys created at $AGE_KEYS"
      fi
    '';
  };

  systemd.services.repo-nightly = {
    description = "Nightly flake update, bootstrap, and nixos-rebuild switch";

    after  = [ "network-online.target" ];
    wants  = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      # runs as root by default (needed for nixos-rebuild)
    };

    # Set env vars at systemd level so git filter subprocesses inherit them
    environment = {
      FILTER_PATH = lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.git
        pkgs.sops
        pkgs.ssh-to-age
      ];
    };

    path = [
      pkgs.bash          # provides bash
      pkgs.git           # git clone/fetch/reset
      pkgs.coreutils     # mktemp, rm, etc.
    ];

    script = ''
      set -euo pipefail

      REPO_URL="${toml.repoUrl}"
      FLAKE_HOST="${config.networking.hostName}"

      TMP_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/repo-nightly-XXXXXX)"
      echo "Cloning into $TMP_DIR"

      # 1) Normal clone (with checkout)
      ${pkgs.git}/bin/git clone "$REPO_URL" "$TMP_DIR"

      cd "$TMP_DIR"

      # 2) Wire up filters (adds include.path=./scripts/git-config.filters)
      ./scripts/bootstrap-git.sh

      echo "Rebuilding system from flake $TMP_DIR#$FLAKE_HOST ..."

      ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
        --flake "$TMP_DIR#$FLAKE_HOST"

      echo "nixos-rebuild switch finished successfully."

      # Optional: clean up temp clone
      # ${pkgs.coreutils}/bin/rm -rf "$TMP_DIR"
    '';
  };

  systemd.timers.repo-nightly = {
    description = "Run repo-nightly flake rebuild at midnight";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "00:00";
      Persistent = true;
    };
  };

  # Zabbix Agent 2 on a proxy/monitored host
  services.zabbixAgent2 = {
    enable = true;
    package = pkgs.zabbix74.agent2;

    # Zabbix proxy / server this host talks to
    server = "127.0.0.1";        # passive checks
    serverActive = "127.0.0.1";  # active checks (can include :port)

    # How this host appears in Zabbix
    hostname = config.networking.hostName;  # must match the host name in Zabbix

    # Listen settings
    listen = {
      ip = null;    # listen on all interfaces (don’t set "0.0.0.0"!)
      port = 10050;
    };

    # Open port 10050 in the firewall
    openFirewall = true;

    # Base agent settings (just some sensible defaults)
    settings = {
      DebugLevel = 3;
      Timeout = 10;
      BufferSend = 5;
      BufferSize = 100;
      AllowKey = [ "system.run[*]" ];
    };

    # Example plugin settings
    # plugins.settings = { };

    # Optional: extra raw config lines
    plugins.extraConfig = ''
      # Include additional plugin configs if you ever need them
      # Include=/etc/zabbix/zabbix_agent2.d/*.conf
    '';

    # Expose internal metrics on localhost:31999/status
    statusPort = 31999;

    # TLS: PSK with auto-generation
    tls = {
      enable = true;       # convenience: sets connect=psk, accept=[psk] and autoGenerate=true
      # If you want more explicit:
      # connect = "psk";
      # accept  = [ "psk" ];

      psk = {
        # autoGenerate.enable is set to true by tls.enable,
        # but you can override bits or identity if you like:
        autoGenerate.bits = 256;  # default, safe
        identity = null;          # null → auto: "PSK_<hostname>"
        file = null;              # null → auto path in /var/lib/zabbix-agent2/psk
      };
    };
  };

  # Zabbix Proxy - forwards data from agents to the main Zabbix server
  services.zabbixProxy = {
    enable = true;
    package = pkgs.zabbix74.proxy-sqlite;

    # Zabbix server this proxy reports to
    server = toml.zabbix.server;

    # Active proxy mode (proxy initiates connection to server)
    # Set to 1 for passive mode (server connects to proxy)
    settings = {
      Hostname = config.networking.hostName;  # Must match Zabbix server config
      ProxyMode = 0;  # 0 = active, 1 = passive
      ConfigFrequency = 60;
      DataSenderFrequency = 5;
      DebugLevel = 3;
      Timeout = 10;

      # TLS/PSK encryption to server (shares PSK with agent)
      TLSConnect = "psk";
      TLSPSKIdentity = "PSK_${config.networking.hostName}";
      TLSPSKFile = "/var/lib/zabbix/psk";
    };

    # Listen for agent connections
    listen = {
      ip = "0.0.0.0";  # all interfaces
      port = 10051;
    };

    openFirewall = true;

    # Use SQLite for local storage (simple, no extra DB needed)
    database = {
      type = "sqlite";
      createLocally = false;
    };
  };

  # Increase file descriptor limit for proxy discovery workers
  systemd.services.zabbix-proxy.serviceConfig.LimitNOFILE = 65535;

  services.netbird = {
    # NetBird daemon + CLI
    enable = true;

    # Single client (wt0) that auto-enrolls using a setup key
    clients.wt0 = {
      # optional: override interface/port if you want different values
      interface = "wt0";
      port = 51820;

      ui.enable = true;

      # Environment variables consumed by `netbird up` on first run.
      # These should come from your secrets TOML:
      # [netbird]
      # management_url = "https://netbird.your-domain.com"
      # admin_url      = "https://app.netbird.io"            # or your self-hosted dashboard
      # setup_key      = "your-setup-key-here"
      environment = {
        NB_MANAGEMENT_URL  = toml.netbird.management_url;
        NB_ADMIN_URL       = toml.netbird.management_url;
        NB_HOSTNAME        = config.networking.hostName;
      };

      login = {
        enable = true;
        setupKeyFile = config.sops.secrets."netbird-setup-key".path;
        ssh = {
          allowServerSsh = true;
          disableAuth = true;
        };
      };

      # Start the client automatically with the system
      autoStart = true;
    };
  };

  system.stateVersion = "25.05";

  #   script = ''
  #     TARGET="age1de0pt6ecp3luz0nnt09grlj4fw4mlfexuwhp6hv3a7uz65p3f55srjj05l"
  #     ED25519_KEY="/etc/ssh/ssh_host_ed25519_key"
  #     RSA_KEY="/etc/ssh/ssh_host_rsa_key"

  #     # Ensure the public key exists before trying to check it
  #     if [ -f "$ED25519_KEY.pub" ]; then
  #       echo "Checking SSH host key fingerprint..."
        
  #       OUTPUT=$(cat "$ED25519_KEY.pub" | ssh-to-age)

  #       if [ "$OUTPUT" == "$TARGET" ]; then
  #         echo "MATCH FOUND: Target key detected. Regenerating host keys..."
          
  #         # Remove old keys (both Ed25519 and RSA)
  #         rm -f "$ED25519_KEY" "$ED25519_KEY.pub" "$RSA_KEY" "$RSA_KEY.pub"
          
  #         # Generate new Ed25519 key
  #         ssh-keygen -t ed25519 -f "$ED25519_KEY" -N "" -C "root@$(hostname)-generated"
          
  #         # Generate new RSA key (4096 bits)
  #         ssh-keygen -t rsa -b 4096 -f "$RSA_KEY" -N "" -C "root@$(hostname)-generated"
          
  #         echo "New ED25519 and RSA key pairs generated successfully."
  #       else
  #         echo "Key check passed (No match). No action taken."
  #       fi
  #     else
  #       echo "No ED25519 public key found to check."
  #     fi
  #   '';
  # };
}