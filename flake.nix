{
  description = "Handy - A free, open source, and extensible speech-to-text application that works completely offline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # bun2nix: generates per-package Nix fetchurl expressions from bun.lock,
    # replacing the old FOD approach where a single hash covered the entire
    # node_modules directory (that hash would break on bun version changes).
    # See: https://github.com/nix-community/bun2nix
    bun2nix = {
      url = "github:nix-community/bun2nix/2.0.8";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      bun2nix,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      # Read version from Cargo.toml
      cargoToml = fromTOML (builtins.readFile ./src-tauri/Cargo.toml);
      version = cargoToml.package.version;
      whisperLargeV3F16 = {
        filename = "whisper-large-v3-F16.gguf";
        repo = "handy-computer/whisper-large-v3-gguf";
        revision = "e3e29bee6389c7da4a141406f07bb80ddac5337c";
        sha256 = "e633ab1d74b0e98f4f57daedaee34291297dbbf01389bda3d890766600c1c584";
      };

      # Shared native library dependencies for both package build and dev shell.
      # Keep in sync: if a native dep is needed for compilation, add it here.
      linuxNativeDeps = pkgs: with pkgs; [
        webkitgtk_4_1
        gtk3
        glib
        libsoup_3
        alsa-lib
        onnxruntime
        libayatana-appindicator
        libevdev
        libxtst
        gtk-layer-shell
        openssl
        vulkan-loader
        vulkan-headers
        shaderc
      ];

      # GStreamer plugins for WebKitGTK audio/video
      gstPlugins = pkgs: with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
      ];

      # Shared environment variables for Rust/native builds
      commonEnv = pkgs: let lib = pkgs.lib; in {
        ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
        ORT_PREFER_DYNAMIC_LINK = "1";
        GST_PLUGIN_SYSTEM_PATH_1_0 = "${lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (gstPlugins pkgs)}";
      };

    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              bun2nix.overlays.default
            ];
          };
          lib = pkgs.lib;
          combinedAlsaPlugins = pkgs.symlinkJoin {
            name = "combined-alsa-plugins";
            paths = [
              "${pkgs.pipewire}/lib/alsa-lib"
              "${pkgs.alsa-plugins}/lib/alsa-lib"
            ];
          };
          tauriXattrShim = pkgs.writeShellApplication {
            name = "xattr";
            text = ''
              if [ "$#" -eq 2 ] && [ "$1" = "-cr" ]; then
                exit 0
              fi

              echo "xattr shim only permits: xattr -cr <app-bundle>" >&2
              exit 64
            '';
          };
        in
        {
          whisper-large-v3-f16 = pkgs.fetchurl {
            inherit (whisperLargeV3F16) sha256;
            name = whisperLargeV3F16.filename;
            url = "https://huggingface.co/${whisperLargeV3F16.repo}/resolve/${whisperLargeV3F16.revision}/${whisperLargeV3F16.filename}";
          };

          handy = pkgs.rustPlatform.buildRustPackage {
            pname = "handy";
            inherit version;
            src = self;

            cargoRoot = "src-tauri";
            buildAndTestSubdir = "src-tauri";
            tauriBundleType = if pkgs.stdenv.hostPlatform.isDarwin then "app" else "deb";

            cargoLock = {
              lockFile = ./src-tauri/Cargo.lock;
              # Automatically fetch git dependencies using builtins.fetchGit.
              # This eliminates the need for manual outputHashes that had to be
              # updated every time a git dependency changed in Cargo.lock.
              # Safe for standalone flakes (not allowed in nixpkgs, it is needed something like crate2nix).
              allowBuiltinFetchGit = true;
            };

            postPatch = ''
              ${pkgs.jq}/bin/jq '${
                if pkgs.stdenv.hostPlatform.isDarwin
                then ".bundle.createUpdaterArtifacts = false | .bundle.macOS.signingIdentity = null"
                else ".bundle.createUpdaterArtifacts = false"
              }' \
                src-tauri/tauri.conf.json > $TMPDIR/tauri.conf.json
              cp $TMPDIR/tauri.conf.json src-tauri/tauri.conf.json

              # Strip postinstall hook — it runs check-nix-deps.ts which is only
              # needed during local development, not inside the Nix sandbox.
              ${pkgs.jq}/bin/jq 'del(.scripts.postinstall)' \
                package.json > $TMPDIR/package.json
              cp $TMPDIR/package.json package.json

              ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
                # Point libappindicator-sys to the Nix store path
                substituteInPlace \
                  $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
                  --replace-fail \
                    "libayatana-appindicator3.so.1" \
                    "${pkgs.libayatana-appindicator}/lib/libayatana-appindicator3.so.1"
              ''}

              # Disable cbindgen in ferrous-opencc (calls cargo metadata which fails in sandbox)
              # Upstream removed this call in v0.3.1+
              substituteInPlace $cargoDepsCopy/ferrous-opencc-0.2.3/build.rs \
                --replace-fail '.expect("Unable to generate bindings")' '.ok();'
              substituteInPlace $cargoDepsCopy/ferrous-opencc-0.2.3/build.rs \
                --replace-fail '.write_to_file("opencc.h");' '// skipped'
            '';

            # Bun dependencies: fetched per-package using hashes from .nix/bun.nix.
            # This file is auto-generated by `bunx bun2nix -o .nix/bun.nix` and
            # kept in sync via the postinstall hook in package.json.
            # To regenerate manually: bun scripts/check-nix-deps.ts
            bunDeps = pkgs.bun2nix.fetchBunDeps {
              bunNix = ./.nix/bun.nix;
            };

            nativeBuildInputs = with pkgs; [
              cargo-tauri.hook
              pkg-config
              bun
              # pkgs.bun2nix (from overlay), not the flake input — `with pkgs;`
              # doesn't shadow function arguments in Nix.
              pkgs.bun2nix.hook # Sets up node_modules from pre-fetched bun cache
              jq
              cmake
              rustPlatform.bindgenHook
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              wrapGAppsHook4
              shaderc
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              swift
              darwin.cctools
              tauriXattrShim
            ];

            # Tests require runtime resources (audio devices, model files, GPU/Vulkan)
            # not available in the Nix build sandbox
            doCheck = false;

            buildInputs = with pkgs; [
              onnxruntime
              openssl
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
              linuxNativeDeps pkgs ++ [
                glib-networking
                libx11
              ] ++ gstPlugins pkgs
            );

            env = {
              ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
              ORT_PREFER_DYNAMIC_LINK = "1";
              OPENSSL_NO_VENDOR = "1";
            }
            // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (commonEnv pkgs)
            // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
              # build.rs supports this override for non-Xcode Swift toolchains.
              SWIFTC = "${pkgs.swift}/bin/swiftc";
              # This deployment uses local Whisper, not FoundationModels.
              HANDY_FORCE_AI_STUB = "1";
            };

            postInstall = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
              app="$out/Applications/Handy.app"
              executable="$app/Contents/MacOS/handy"
              frameworks="$app/Contents/Frameworks"
              mkdir -p "$frameworks"
              cp -L \
                "${pkgs.onnxruntime}/lib/libonnxruntime.${pkgs.onnxruntime.version}.dylib" \
                "$frameworks/libonnxruntime.dylib"
              chmod u+w "$executable" "$frameworks/libonnxruntime.dylib"
              install_name_tool \
                -change \
                "@rpath/libonnxruntime.${pkgs.onnxruntime.version}.dylib" \
                "@executable_path/../Frameworks/libonnxruntime.dylib" \
                "$executable"
              install_name_tool \
                -id "@rpath/libonnxruntime.dylib" \
                "$frameworks/libonnxruntime.dylib"
            '';

            preFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              gappsWrapperArgs+=(
                --set WEBKIT_DISABLE_DMABUF_RENDERER 1
                --set ALSA_PLUGIN_DIR "${combinedAlsaPlugins}"
                # Self-update can't work against an immutable /nix/store install
                # (downloadAndInstall would try to overwrite the store path), so
                # the Nix-built package always disables the updater.
                --set HANDY_DISABLE_UPDATER 1
              )
            '';

            meta = {
              description = "A free, open source, and extensible speech-to-text application that works completely offline";
              homepage = "https://github.com/cjpais/Handy";
              license = lib.licenses.mit;
              mainProgram = "handy";
              platforms = supportedSystems;
            };
          };

          default = self.packages.${system}.handy;
        }
      );

      # NixOS module for system-level integration (udev, input group)
      nixosModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/module.nix ];
          programs.handy.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.handy;
        };

      # Home-manager module for per-user service
      homeManagerModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/hm-module.nix ];
          services.handy.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.handy;
        };

      darwinModules.default =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/darwin-module.nix ];
          programs.handy.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.handy;
          programs.handy.modelPackage =
            lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.whisper-large-v3-f16;
        };

      # Development shell for building from source
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        {
          default = pkgs.mkShell ({
            buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (linuxNativeDeps pkgs) ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin (with pkgs; [
              swift
              darwin.cctools
            ]) ++ (with pkgs; [
              # Rust toolchain
              rustc
              cargo
              rust-analyzer
              clippy
              rustfmt
              # Frontend
              nodejs
              bun
              # Build tools
              cargo-tauri
              pkg-config
              rustPlatform.bindgenHook
              cmake
            ]);

            ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
            ORT_PREFER_DYNAMIC_LINK = "1";

            shellHook = ''
              echo "Handy development environment"
              bun install
              echo "Run 'bun run tauri dev' to start"
            '';
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            inherit (commonEnv pkgs) GST_PLUGIN_SYSTEM_PATH_1_0;
            LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.libayatana-appindicator pkgs.onnxruntime pkgs.vulkan-loader ]}";
            # Same as wrapGAppsHook4
            XDG_DATA_DIRS = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:${pkgs.hicolor-icon-theme}/share";
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            SWIFTC = "${pkgs.swift}/bin/swiftc";
            HANDY_FORCE_AI_STUB = "1";
          });
        }
      );
    };
}
