{
    # Snowfall Lib provides a customized `lib` instance with access to your flake's library
    # as well as the libraries available from your flake's inputs.
    lib,
    # An instance of `pkgs` with your overlays and packages applied is also available.
    pkgs,
    # You also have access to your flake's inputs.
    inputs,

    # Additional metadata is provided by Snowfall Lib.
    namespace, # The namespace used for your flake, defaulting to "internal" if not set.
    home, # The home architecture for this host (eg. `x86_64-linux`).
    target, # The Snowfall Lib target for this home (eg. `x86_64-home`).
    format, # A normalized name for the home target (eg. `home`).
    virtual, # A boolean to determine whether this home is a virtual target using nixos-generators.
    host, # The host name for this home.

    # All other arguments come from the home home.
    config,
    sops,
    ...
}:
{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "nixos";
  home.homeDirectory = "/home/nixos";

  home.stateVersion = "25.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    htop
    starship
    file
  ];

  programs.zsh = {
    enable = true;
    autocd = true;
    oh-my-zsh = {
      enable = true;
      package = pkgs.jinx.oh-my-zsh;
      plugins = [
        "git"
        "sudo"
        "starship"
      ];
      theme = "lukerandall";
      extraConfig = ''
        zstyle ':omz:update' mode reminder
        eval "$(starship init zsh)"
      '';
    };
  };
}