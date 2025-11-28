{
  lib,
  inputs,
  ...
}: let
  inherit (inputs) deploy-rs nixpkgs;
in rec {
  mkDeploy = {
    self,
    overrides ? {},
  }: let
    hosts = self.nixosConfigurations or {};
    names = builtins.attrNames hosts;
    nodes =
      lib.foldl
      (result: name: let
        host = hosts.${name};
        user = host.config.deploy.user or null;
        sshUser = host.config.deploy.sshUser or null;
        default_hm = host.config.deploy.default_hm or false;
        remoteBuild = host.config.deploy.remoteBuild or null;
        
        inherit (host.pkgs) system;
        # pkgs = import nixpkgs { inherit (host.pkgs) system; };
        deployPkgs = import nixpkgs {
          inherit (host.pkgs) system;
          overlays = [
            deploy-rs.overlays.default
            (self: super: { deploy-rs = { inherit (host.pkgs) deploy-rs; lib = super.deploy-rs.lib; }; })
          ];
        };
      in
        result
        // {
          ${name} =
            (overrides.${name} or {})
            // {
              hostname = if ( host.config.deploy.address != null ) 
                then host.config.deploy.address 
                else overrides.${name}.hostname or "${name}";
              profilesOrder = [ "system" ];
              profiles =
                (overrides.${name}.profiles or {})
                // {
                  system =
                    (overrides.${name}.profiles.system or {})
                    // {
                      path = deployPkgs.deploy-rs.lib.activate.nixos host;
                    }
                    // ( if (sshUser == null) 
                        then { sshUser = "nixos"; }
                        else { sshUser = sshUser; }
                    )
                    // { user = "root"; }
                    // lib.optionalAttrs (remoteBuild != null) {
                      remoteBuild = remoteBuild;
                    };
                }
                // ( if ( user != null ) 
                  then {
                    home =
                      (overrides.${name}.profiles.user or {})
                      // {
                        path = 
                        if (self.homeConfigurations ? "${user}@${name}")
                          then deployPkgs.deploy-rs.lib.activate.home-manager self.homeConfigurations."${user}@${name}"
                          else deployPkgs.deploy-rs.lib.activate.home-manager self.homeConfigurations."${user}@default";
                      }
                      // lib.optionalAttrs (sshUser == null) {
                        sshUser = "nixos";
                      }
                      // lib.optionalAttrs (sshUser != null && user != null) {
                        user = user;
                        sshUser = sshUser;
                      }
                      // lib.optionalAttrs (remoteBuild != null) {
                        remoteBuild = remoteBuild;
                      };
                  }
                  else {}
                );
                };
            })
      {}
      names;
  in {inherit nodes;};
}
