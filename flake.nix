{
  description = "Scylla development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Overlay that converts Fedora RPMs into Nix derivations
        rpmOverlay = (self: super:
          let
            # helper function for RPM‑based derivations
            mkRPM = { pname, version, url, sha256 ? "0000000000000000000000000000000000000000000000000000" }:
              super.stdenv.mkDerivation rec {
                inherit pname version;
                src = super.fetchurl { inherit url sha256; };
                nativeBuildInputs = [ super.rpm super.cpio ];
                phases = [ "installPhase" ];
                installPhase = ''
                  mkdir -p $out
                  rpm2cpio $src | (cd $out; cpio -idmv)
                  # flatten /usr so binaries end up in $out/bin, jars in $out/share, etc.
                  if [ -d $out/usr ]; then
                    mv $out/usr/* $out/
                    rmdir -p --ignore-fail-on-non-empty $out/usr || true
                  fi
                '';
              };
          in rec {
            # ------------------------------------------------------------------
            # Fedora 41 RPMs to be integrated
            # ------------------------------------------------------------------
            antlr3Tool = mkRPM {
              pname = "antlr3Tool";
              version = "3.5.3";
              url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/Packages/a/antlr3-tool-3.5.3-11.fc41.noarch.rpm";
              sha256 = "sha256-EueMjK4TvCpS3V9jte3KbUxxrT/nnR6iH995eQ/leEU=";
            };

            antlr3Java = mkRPM {
              pname = "antlr3Java";
              version = "3.5.3";
              url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/Packages/a/antlr3-java-3.5.3-11.fc41.noarch.rpm";
              sha256 = "sha256-aZlrqQZajeTRA9zzSegBSlo5QswgxQuugSRBaejDGuw=";
            };

            antlr3CppDevel = mkRPM {
              pname = "antlr3CppDevel";
              version = "3.5.3";
              url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/Packages/a/antlr3-C++-devel-3.5.3-11.fc41.x86_64.rpm";
              sha256 = "sha256-W2/LONn8Qk8OWdm0B1UsQln9f9opnQniwaONvlXUqXo=";
            };

            stringtemplate4 = mkRPM {
              pname = "stringtemplate4";
              version = "4.3.4";
              url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/Packages/s/stringtemplate4-4.3.4-5.fc41.noarch.rpm";
              sha256 = "sha256-eD42M243fakt2v3xeq8k458j91sYbR64Irp+vKaXe7Y=";
            };
          }
        );

        overlays = [
          (import rust-overlay) rpmOverlay
          rust-overlay.overlays.default
          (final: prev: {
            llvmPackages_19 = prev.llvmPackages_19.override {
              targets = prev.lib.unique (prev.llvmPackages_19.targets ++ [ "WebAssembly" ]);
            };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; };

      in {
        # Expose the new RPM‑based packages so they can be referenced with
        # "nix build .#antlr3Tool" and the like.
        packages = {
          inherit (pkgs) antlr3Tool antlr3Java antlr3CppDevel stringtemplate4;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # antlr3
            antlr3Tool
            antlr3Java
            antlr3CppDevel
            stringtemplate4
            # wasm
            binaryen
            wabt
            # builder
            cmake
            ninja
            pkg-config
            llvmPackages_19.clang
            llvmPackages_19.lld
            gcc
            ragelDev
            valgrind
            doxygen
            # libs
            boost183
            lua5_4_compat
            yaml-cpp
            jsoncpp
            rapidjson
            systemdLibs
            cryptopp
            hwloc
            snappy
            libdeflate
            xxHash
            zstd
            lz4.lib
            lz4.dev
            rapidxml
            fmt_11
            lksctp-tools
            liburing
            numactl
            gnutls
            gmp
            libunistring
            nettle
            libtasn1
            libidn2
            p11-kit
            p11-kit.dev
            zlib
            brotli
            protobuf
            openssl
            libxcrypt
            openldap
            icu
            libffi
            libcap
            libevent
            cyrus_sasl
            cpp-jwt
            c-ares
            libsystemtap
            libxfs
            # rust
            (rust-bin.stable.latest.default.override {
              targets = [ "wasm32-wasip1"];
            })
            # python
            python313
            python313Packages.pyyaml
            python313Packages.urwid
            python313Packages.pyparsing
            python313Packages.requests
            python313Packages.setuptools
            python313Packages.psutil
            python313Packages.distro
            python313Packages.click
            python313Packages.six
            python313Packages.pyudev
          ];
          shellHook = ''
            cargo install cxxbridge-cmd
            export PATH=~/.cargo/bin:$PATH
            export CPATH=${pkgs.p11-kit.dev}/include/p11-kit-1:$CPATH
          '';
        };
      }
    );
}
