{
  description = "Jinx Flakes";

  inputs = {
    # Pin to known-good nixpkgs revision from a few days ago
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    jinx-pkgs.url = "github:jinxcappa/nix-pkgs";
    jinx-pkgs.inputs.nixpkgs.follows = "nixpkgs";

    snowfall-lib = {
      url = "github:snowfallorg/lib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: 
    let
      lib = inputs.snowfall-lib.mkLib {
        inherit inputs;

        src = ./.;

        snowfall = {
          root = ./.;

          namespace = "aulogix";

          meta = {
            name = "monitor-flake";

            title = "Monitor Flake";
          };
        };
      };
    in
      lib.mkFlake {
        overlays = with inputs; [
          # my-inputs.overlays.my-overlay
        ];
        channels-config = {
          allowUnfree = true;
        };

        systems.modules.nixos = with inputs; [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];

        homes.modules = with inputs; [
          sops-nix.homeManagerModules.sops
        ];

        deploy = lib.mkDeploy {inherit (inputs) self;};

        checks =
          builtins.mapAttrs
          (system: deploy-lib:
            deploy-lib.deployChecks inputs.self.deploy)
          inputs.deploy-rs.lib;
      };
}
