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
            version = "2026.04.26";
            src = pkgs.fetchurl {
              url = "https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${version}/riscv64-elf-ubuntu-24.04-gcc.tar.xz";
              hash = "sha256-SmajKWU8nPuGm4Jsrm1wxgO+3MHhPUGdPj6SuZ4IFrE=";
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
          sail-riscv = pkgs.stdenv.mkDerivation rec {
            pname = "sail-riscv";
            version = "0.11";
            src = pkgs.fetchurl {
              url = "https://github.com/riscv/sail-riscv/releases/download/${version}/sail-riscv-Linux-x86_64.tar.gz";
              hash = "sha256-JFRY4WDN7dQurOh5ViQS6MCMrq962h+9pE2AfaNBc6g=";
            };
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -a ./. $out/
              runHook postInstall
            '';
          };
          morty = pkgs.stdenv.mkDerivation rec {
            pname = "morty";
            version = "0.9.0";
            src = pkgs.fetchurl {
              url = "https://github.com/pulp-platform/morty/releases/download/v${version}/morty-ubuntu.22.04-x86_64.tar.gz";
              hash = "sha256-/EZl0ynsGLEGgl37sdDM9gDR0FJQi6M87IlwlEj7sys=";
            };
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [ pkgs.stdenv.cc.cc.lib ];
            sourceRoot = ".";
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 morty $out/bin/morty
              runHook postInstall
            '';
          };
          svase = pkgs.stdenv.mkDerivation rec {
            pname = "svase";
            version = "0.1.0-alpha";
            src = pkgs.fetchurl {
              url = "https://github.com/pulp-platform/svase/releases/download/v${version}/svase-linux_v${version}.zip";
              hash = "sha256-6btwL2y5znNgQmN0CwcsTUAXckQORuRfWT9WTHuqAIM=";
            };
            nativeBuildInputs = [ pkgs.unzip pkgs.patchelf ];
            sourceRoot = ".";
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 svase $out/bin/svase
              runHook postInstall
            '';
            postFixup = ''
              patchelf \
                --set-interpreter ${pkgs.musl}/lib/ld-musl-x86_64.so.1 \
                --set-rpath ${pkgs.musl}/lib \
                $out/bin/svase
            '';
          };
        in {
          default = pkgs.mkShell {
            name = "friscv-tapeout";
            packages = (with pkgs; [
              yosys
              iverilog
              verilator
              bender
              ngspice
              gtkwave
              klayout
              magic
              netgen
              mise
              uv
              haskellPackages.sv2v
            ]) ++ [
              openroad
              riscv-toolchain
              sail-riscv
              morty
              svase
            ];
          };
        });
    };
}
