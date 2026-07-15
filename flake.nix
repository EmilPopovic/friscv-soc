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
          librelane-pkg = librelane.packages.${system}.librelane
            or librelane.packages.${system}.default;
          librelane-manual-pdk = pkgs.symlinkJoin {
            name = "librelane-manual-pdk";
            paths = [ librelane-pkg ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              rm $out/bin/librelane
              makeWrapper ${librelane-pkg}/bin/librelane $out/bin/librelane \
                --add-flags "--manual-pdk"
            '';
          };
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
          mise = pkgs.stdenv.mkDerivation rec {
            pname = "mise";
            version = "2026.7.5";
            src = pkgs.fetchurl {
              url = "https://github.com/jdx/mise/releases/download/v${version}/mise-v${version}-linux-x64.tar.gz";
              hash = "sha256-vpLaOvsYDccbPOb8qq8vOTgSycUOmmTJy2cGzyjttIY=";
            };
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [ pkgs.stdenv.cc.cc.lib ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 bin/mise $out/bin/mise
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
          yosys-full = nix-eda.packages.${system}.yosysFull;
          ihp-pdk = pkgs.fetchFromGitHub {
            owner = "IHP-GmbH";
            repo = "IHP-Open-PDK";
            rev = "22f2a25f1734796de3debbbf29cf697cbbc54081";
            hash = "sha256-MvJn3QmIA+Ixaq9XERTT2lVFo9x+9G4VvtdOyR+mM+Q=";
          };
          ihp-liberty = "${ihp-pdk}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib";
          ihp-cmos5l-pdk = pkgs.fetchFromGitHub {
            owner = "IHP-GmbH";
            repo = "ihp-sg13cmos5l";
            rev = "33fd51900e07260ad0044ae4af22dd15ed10c764"; # v0.2.0
            hash = "sha256-IhidmbbWyxWduV4ZuZSUAPN+LBl34s1l3WuVRd2AVlM=";
          };
          pdk-root = pkgs.runCommand "ihp-pdk-root" { } ''
            mkdir -p $out
            ln -s ${ihp-pdk}/ihp-sg13g2 $out/ihp-sg13g2
            cp -a ${ihp-cmos5l-pdk} $out/ihp-sg13cmos5l
          '';
        in {
          default = pkgs.mkShell {
            name = "friscv-tapeout";
            LIBERTY = ihp-liberty;
            PDK_ROOT = "${pdk-root}";
            PDK = "ihp-sg13g2";
            packages = (with pkgs; [
              iverilog
              verilator
              bender
              ngspice
              gtkwave
              klayout
              magic
              netgen
              openocd
              uv
              haskellPackages.sv2v
            ]) ++ [
              mise
              yosys-full
              openroad
              librelane-manual-pdk
              riscv-toolchain
              sail-riscv
              morty
              svase
            ];
          };

          act = pkgs.mkShell {
            name = "friscv-act";
            packages = (with pkgs; [
              bender
              python3
              verilator
            ]) ++ [
              mise
              riscv-toolchain
              sail-riscv
            ];
          };
        });
    };
}
