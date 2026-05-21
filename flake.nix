{
  description = "ExpressVPN v14.x (Qt App) package + NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            }
          )
        );
    in
    {
      packages = forAllSystems (pkgs: {
        expressvpn = pkgs.callPackage ./package.nix { };
        default = pkgs.callPackage ./package.nix { };
      });

      overlays.default = final: _prev: {
        expressvpn = final.callPackage ./package.nix { };
      };

      nixosModules.default = ./module.nix;
      nixosModules.expressvpn = ./module.nix;

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
