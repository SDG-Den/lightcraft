# `programs.lightcraft` for NixOS and home-manager.
#
# The option set is shared; `kind` selects only the behaviour the target module system can express:
# home-manager writes the settings overlay and the palette variable per user, NixOS installs the
# package and the MIME defaults for the whole system. NixOS cannot write per-user files, so it never
# writes `settings`.
#
# The overlay is `settings.override.json` beside `ui.json` (`apps/lightcraft/src/prefs.rs`), merged
# over the saved settings at start-up. LightCraft never writes it, so the declarative values survive
# a normal save. `ui.json` also holds window and docking state, so overlay only the preference keys
# there.
{ kind }:
{
  config,
  lib,
  pkgs,
  # The package of this flake; `flake.nix` passes it through `_module.args`, so importing the
  # module directly needs no overlay.
  lightcraftPackage ? pkgs.lightcraft,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.lightcraft;

  jsonFormat = pkgs.formats.json { };

  # The same list as `packaging/linux/ai.storyteller.lightcraft.desktop` (`MimeType=`).
  mimeTypes = [
    "image/heic"
    "image/heif"
    "image/jpeg"
    "image/png"
    "image/tiff"
    "image/webp"
    "image/x-adobe-dng"
    "image/x-sony-arw"
    "image/x-canon-cr2"
    "image/x-canon-cr3"
    "image/x-nikon-nef"
    "image/x-fuji-raf"
    "image/x-olympus-orf"
    "image/x-panasonic-rw2"
    "image/x-panasonic-rw"
    "image/x-pentax-pef"
  ];

  desktopFile = "ai.storyteller.lightcraft.desktop";

  # The per-user settings directory: `$XDG_CONFIG_HOME/lightcraft` on Linux.
  settingsDir = "${config.xdg.configHome}/lightcraft";

  associations = lib.genAttrs mimeTypes (_: [ desktopFile ]);
in
{
  options.programs.lightcraft = {
    enable = mkEnableOption "LightCraft";

    package = mkOption {
      type = types.package;
      default = lightcraftPackage;
      defaultText = lib.literalMD "the `lightcraft` package of this flake";
      description = "The LightCraft package to install.";
    };

    setAsDefault = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the image and raw formats LightCraft handles with it by default (the MIME types of
        `packaging/linux/ai.storyteller.lightcraft.desktop`).
      '';
    };

    settings = mkOption {
      type = jsonFormat.type;
      default = { };
      description = ''
        Free-form preferences merged over the app's settings. Home-manager writes them to
        `settings.override.json`; NixOS ignores them, because it cannot write per-user files.
      '';
    };

    paletteFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional shared palette file, exported as `CRAFT_PALETTE_FILE`. Inert until theming support
        lands.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable (
      if kind == "nixos" then
        {
          environment.systemPackages = [ cfg.package ];
          environment.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          xdg.mime.defaultApplications = mkIf cfg.setAsDefault associations;
        }
      else
        {
          home.packages = [ cfg.package ];
          home.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          home.file."${settingsDir}/settings.override.json" = mkIf (cfg.settings != { }) {
            source = jsonFormat.generate "lightcraft-settings.override.json" cfg.settings;
          };
          xdg.mimeApps = mkIf cfg.setAsDefault {
            enable = true;
            defaultApplications = associations;
            # Associated even when another application stays the default.
            associations.added = associations;
          };
        }
    ))
  ];
}
