{
  description = "FRISC-V tapeout toolchain";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.fossi-foundation.org" ];
    extra-trusted-public-keys = [
      "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
    ];
  };

  inputs = {
    nix-eda.url = "github:fossi-foundation/nix-eda";

    nixpkgs.follows = "nix-eda/nixpkgs";

    librelane = {
      url = "github:librelane/librelane";
      inputs.nix-eda.follows = "nix-eda";
    };
  };

  outputs = { self, nixpkgs, nix-eda, librelane }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ nix-eda.overlays.default ];
          };
          openroad = librelane.packages.${system}.openroad
            or librelane.legacyPackages.${system}.openroad;
        in {
          default = pkgs.mkShell {
            name = "friscv-tapeout";
            packages = (with pkgs; [
              yosys
              iverilog
              verilator
              ngspice
              gtkwave
              klayout
              magic
              netgen
            ]) ++ [
              openroad
            ];
          };
        });
    };
}
