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
          riscv-toolchain = pkgs.stdenv.mkDerivation rec {
            pname = "riscv64-unknown-elf-toolchain";
            version = "2026.06.06";
            src = pkgs.fetchurl {
              url = "https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${version}/riscv64-elf-ubuntu-24.04-gcc.tar.xz";
              hash = "sha256-NzhiQYJWiHCB4IdoVwdux4UucSkrfoxVGM8Cf8stk7U=";
            };
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = with pkgs; [
              stdenv.cc.cc.lib
              zlib
              zstd
              expat
              gmp
              mpfr
              libmpc
              ncurses
              glib
              python312
            ];
            dontStrip = true;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -a ./. $out/
              runHook postInstall
            '';
          };
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
              riscv-toolchain
            ];
          };
        });
    };
}
