{
  description = "A Nix-flake-based development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix?rev=c28e93f3ba133d4c1b1d65224e2eebede61fd071";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig, zon2nix, rust-overlay }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSupportedSystem = f: lib.genAttrs supportedSystems (system: f rec {
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ rust-overlay.overlays.default ];
        };
        zigPkg = zig.packages.${system}."0.15.2";
        zon2nixPkg = zon2nix.packages.${system}.zon2nix;
      });
    in
    {
      packages = forEachSupportedSystem ({ pkgs, zigPkg, ... }: {
        # ghostty/build.zig.zon.nix lives in a submodule, invisible to nix
        # flakes.  CI copies it to nix/ghostty-deps.nix before evaluation
        # (see `just stage-zig-deps`).
        deps = pkgs.symlinkJoin {
          name = "zig-packages";
          paths = [
            (pkgs.callPackage ./nix/ghostty-deps.nix { zig_0_15 = zigPkg; })
            (pkgs.callPackage ./nix/extra-zig-deps.nix { zig_0_15 = zigPkg; })
          ];
        };
        default = pkgs.rustPlatform.buildRustPackage {
          pname = "trolley";
          version = (lib.importTOML ./cli/Cargo.toml).package.version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./VERSION
              ./cli
              ./config
            ];
          };
          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = ["-p" "trolley"];
          env.TROLLEY_RUNTIME_SOURCE = "https://github.com/weedonandscott/trolley/releases/download/v{version}/trolley-runtime-{target}.tar.xz";
          nativeBuildInputs = [ pkgs.pkg-config ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.makeWrapper ];
          # No Darwin framework inputs needed: the Darwin stdenv ships the
          # Apple SDK (Security, SystemConfiguration, ...) since the
          # darwin.apple_sdk compatibility layer was removed from nixpkgs.
          buildInputs = [ pkgs.xz ];
          # The runtime binary is self-contained (only needs libc) but GLFW
          # loads X11/Wayland/GL at runtime via dlopen.  On NixOS these live
          # in the Nix store, so wrap the CLI with LD_LIBRARY_PATH.
          postFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            wrapProgram $out/bin/trolley \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath (with pkgs; [
                libGL
                libxkbcommon
                xorg.libX11
                xorg.libXcursor
                xorg.libXext
                xorg.libXi
                xorg.libXinerama
                xorg.libXrandr
                wayland
              ])}"
          '';
        };
      });

      devShells = forEachSupportedSystem ({ pkgs, zigPkg, zon2nixPkg, ... }:
        let
          # Musl-targeting C compiler for static CLI builds on Linux.
          # Not added to PATH to avoid conflicts with the host glibc toolchain
          # used by Zig for the runtime.  Passed to cargo/cc-crate via env vars.
          muslCC = pkgs.pkgsMusl.stdenv.cc;
        in {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # trolley build toolchain
            zigPkg
            pkg-config

            # Rust — custom toolchain with musl target for static CLI builds
            (rust-bin.stable.latest.default.override {
              extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
              targets = lib.optionals stdenv.hostPlatform.isLinux [
                (if stdenv.hostPlatform.isx86_64
                 then "x86_64-unknown-linux-musl"
                 else "aarch64-unknown-linux-musl")
              ];
            })

            # Task runner
            just

            # CI
            act
            zon2nixPkg

            # OpenTUI example
            bun

            # Bubbletea example
            go
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            # X11 headers (needed at compile time for GLFW source build)
            libxkbcommon
            libx11
            libxcursor
            libxext
            libxi
            libxinerama
            libxrandr
            libxrender
            libxfixes
            # Wayland headers + code generator (needed at compile time for GLFW)
            wayland
            wayland-scanner
          ];

          shellHook = lib.optionalString pkgs.stdenv.hostPlatform.isLinux (''
            # GLFW loads X11/Wayland/GL at runtime via dlopen.  On NixOS
            # these live in the Nix store, so set LD_LIBRARY_PATH.
            export LD_LIBRARY_PATH="${lib.makeLibraryPath (with pkgs; [
              libGL
              libxkbcommon
              xorg.libX11
              xorg.libXcursor
              xorg.libXext
              xorg.libXi
              xorg.libXinerama
              xorg.libXrandr
              wayland
            ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '' + (if pkgs.stdenv.hostPlatform.isx86_64 then ''
            # Musl C compiler/linker for static CLI builds (not on PATH to
            # avoid conflicts with glibc toolchain used by Zig runtime).
            export CC_x86_64_unknown_linux_musl="${muslCC}/bin/cc"
            export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="${muslCC}/bin/cc"
          '' else ''
            export CC_aarch64_unknown_linux_musl="${muslCC}/bin/cc"
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${muslCC}/bin/cc"
          '')) + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # Ghostty's build.zig eagerly builds for iOS even when we only need
            # macOS. Nix only ships a macOS SDK, so we unset Nix's SDK env vars
            # and let Zig discover the system Xcode which has all Apple SDKs.
            unset SDKROOT
            unset DEVELOPER_DIR
            export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')
          '';
        };
      });
    };

  nixConfig = {
    extra-substituters = ["https://trolley.cachix.org"];
    extra-trusted-public-keys = ["trolley.cachix.org-1:j4ckLzEzdt+r2MOinJiaT/uWS+febWBnho9wqejHQUQ="];
  };
}
