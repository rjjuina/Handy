{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.handy;
  homeDirectory = if cfg.homeDirectory == null then "/Users/${cfg.user}" else cfg.homeDirectory;
  appPath = "${homeDirectory}/Applications/Handy.app";
  modelDirectory = "${homeDirectory}/Library/Application Support/com.pais.handy/models";
  modelPath = "${modelDirectory}/whisper-large-v3-F16.gguf";

  installHandy = pkgs.writeShellApplication {
    name = "install-handy-macos";
    text = ''
      source_app="$1"
      target_app="$2"
      model_source="$3"
      model_target="$4"
      signing_identity="$5"
      expected_fingerprint="$6"

      actual_fingerprint=$(/usr/bin/security find-certificate -c "$signing_identity" -Z \
        | /usr/bin/awk '/SHA-256 hash:/{print $3; exit}')
      expected_fingerprint=$(printf '%s' "$expected_fingerprint" | /usr/bin/tr -d ': ' | /usr/bin/tr '[:lower:]' '[:upper:]')

      if [ -z "$actual_fingerprint" ] || [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
        echo "Handy signing certificate fingerprint mismatch" >&2
        exit 1
      fi

      target_parent=$(/usr/bin/dirname "$target_app")
      staging_app="$target_parent/.Handy.app.staging"
      previous_app="$target_parent/.Handy.app.previous"
      /bin/mkdir -p "$target_parent" "$model_target"
      if [ -e "$staging_app" ]; then
        /bin/chmod -R u+w "$staging_app"
      fi
      if [ -e "$previous_app" ]; then
        /bin/chmod -R u+w "$previous_app"
      fi
      /bin/rm -rf "$staging_app" "$previous_app"
      /usr/bin/ditto "$source_app" "$staging_app"
      /bin/chmod -R u+w "$staging_app"
      /usr/bin/xattr -cr "$staging_app"
      /usr/bin/codesign --force --deep --sign "$signing_identity" "$staging_app"
      /usr/bin/codesign --verify --deep --strict "$staging_app"

      if [ -e "$target_app" ]; then
        /bin/mv "$target_app" "$previous_app"
      fi
      /bin/mv "$staging_app" "$target_app"
      /bin/rm -rf "$previous_app"
      /bin/ln -sfn "$model_source" "$model_target/whisper-large-v3-F16.gguf"
    '';
  };
in
{
  options.programs.handy = {
    enable = lib.mkEnableOption "Handy offline speech-to-text on macOS";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Handy macOS application package.";
    };

    modelPackage = lib.mkOption {
      type = lib.types.package;
      description = "Pinned Whisper Large v3 F16 model file.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "User that runs Handy and owns its signing identity.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Home directory override; defaults to /Users/<user>.";
    };

    signingIdentity = lib.mkOption {
      type = lib.types.str;
      description = "Name of this Mac's self-signed Code Signing identity.";
    };

    signingCertificateSha256 = lib.mkOption {
      type = lib.types.strMatching "([[:xdigit:]]{2}:?){31}[[:xdigit:]]{2}";
      description = "Expected public SHA-256 fingerprint of the signing certificate.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.handy is only supported on Darwin by this module";
      }
    ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      handy_uid=$(/usr/bin/id -u ${lib.escapeShellArg cfg.user})
      /bin/launchctl asuser "$handy_uid" \
        /usr/bin/sudo --user=${lib.escapeShellArg cfg.user} -- \
        ${installHandy}/bin/install-handy-macos \
        ${lib.escapeShellArg "${cfg.package}/Applications/Handy.app"} \
        ${lib.escapeShellArg appPath} \
        ${lib.escapeShellArg cfg.modelPackage} \
        ${lib.escapeShellArg modelDirectory} \
        ${lib.escapeShellArg cfg.signingIdentity} \
        ${lib.escapeShellArg cfg.signingCertificateSha256}
    '';

    launchd.user.agents.handy.serviceConfig = {
      ProgramArguments = [ "${appPath}/Contents/MacOS/handy" "--start-hidden" ];
      EnvironmentVariables.HANDY_DISABLE_UPDATER = "1";
      RunAtLoad = true;
      KeepAlive = { SuccessfulExit = false; };
      ThrottleInterval = 30;
      ProcessType = "Interactive";
    };
  };
}
