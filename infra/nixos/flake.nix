{
  description = "NixOS hosts managed from kuberseni-gitops: gw, the home router (replacing OPNSense)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkHost =
        host:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            inputs.sops-nix.nixosModules.sops
            self.nixosModules.router
            ./hosts/common.nix
            host
          ];
        };
    in
    {
      nixosModules.router = ./modules/router.nix;

      nixosConfigurations = {
        gw = mkHost ./hosts/gw;
        gw-staging = mkHost ./hosts/gw-staging;
      };

      # `nix flake check` builds both hosts and runs the router VM test.
      checks.${system} = {
        router = pkgs.testers.runNixOSTest (import ./tests/router.nix { inherit self; });
        gw = self.nixosConfigurations.gw.config.system.build.toplevel;
        gw-staging = self.nixosConfigurations.gw-staging.config.system.build.toplevel;
      };

      # Proxmox backups (.vma.zst) for the first install: `qmrestore <file> <vmid>`.
      packages.${system} = {
        gw-vma = self.nixosConfigurations.gw.config.system.build.VMA;
        gw-staging-vma = self.nixosConfigurations.gw-staging.config.system.build.VMA;
      };
    };
}
