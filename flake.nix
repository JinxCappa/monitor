{
  description = "Monitor Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    jinx-pkgs.url = "github:jinxcappa/nix-pkgs";
    jinx-modules.url = "github:JinxCappa/nix-modules";

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

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      flakeOutputs = inputs.jinx-modules.lib.mkFlake {
        inherit inputs;
        src = ./.;
        overlays = inputs.jinx-pkgs.lib.overlays.cached;

        customLib = inputs.jinx-modules.lib;

        commonNixosModules = with inputs; [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          jinx-modules.nixosModules.default
        ];

        commonHomeModules = with inputs; [
          sops-nix.homeManagerModules.sops
        ];
      };

      deploy = inputs.jinx-modules.lib.mkDeploy {
        inherit self;
        inherit (inputs) deploy-rs nixpkgs;
      };

    in flakeOutputs // {
      inherit deploy;

      checks = builtins.mapAttrs
        (system: deploy-lib: deploy-lib.deployChecks self.deploy)
        (nixpkgs.lib.filterAttrs (system: _: nixpkgs.lib.hasSuffix "-linux" system) inputs.deploy-rs.lib);
    };
}
