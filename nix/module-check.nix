# Evaluates both module entry points with `enable = true` and checks what they configure.
#
# `lib.evalModules` plus stub declarations of the handful of NixOS/home-manager options the module
# touches: a full NixOS evaluation would need the whole nixpkgs module set, and the stubs keep the
# check to the module's own contract. A wrong option type, a missing option, or a behaviour that
# regresses fails evaluation, so `nix flake check` catches it.
{
  lib,
  pkgs,
  lightcraft,
}:

let
  inherit (lib) mkEnableOption mkOption types;

  palette = ../packaging/linux/ai.storyteller.lightcraft.desktop;

  configHome = "/home/test/.config";
  settingsFile = "${configHome}/lightcraft/settings.override.json";

  desktopFile = "ai.storyteller.lightcraft.desktop";

  # Must match `packaging/linux/ai.storyteller.lightcraft.desktop`.
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

  expected = lib.genAttrs mimeTypes (_: [ desktopFile ]);

  nixosStub = _: {
    options = {
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      environment.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.mime.defaultApplications = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
      };
    };
  };

  homeStub = _: {
    options = {
      home.packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      home.file = mkOption {
        type = types.attrsOf types.anything;
        default = { };
      };
      home.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.configHome = mkOption {
        type = types.str;
        default = configHome;
      };
      xdg.mimeApps = mkOption {
        default = { };
        type = types.submodule {
          options = {
            enable = mkEnableOption "mimeApps";
            defaultApplications = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
            associations.added = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
          };
        };
      };
    };
  };

  evalModule =
    kind: setAsDefault: settings:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (import ./module.nix { inherit kind; })
        (if kind == "nixos" then nixosStub else homeStub)
        {
          programs.lightcraft = {
            enable = true;
            package = lightcraft;
            inherit setAsDefault settings;
            paletteFile = palette;
          };
        }
      ];
    };

  nixos = evalModule "nixos" true { thumbSize = 260; };
  nixosPlain = evalModule "nixos" false { };
  home = evalModule "home-manager" true { thumbSize = 260; };
  homePlain = evalModule "home-manager" false { };

  binaryStub = pkgs.runCommand "lightcraft-binary-stub" { } "touch $out";

  evalDefault =
    useBinary: binary:
    lib.evalModules {
      specialArgs = {
        inherit pkgs;
        lightcraftSourcePackage = lightcraft;
        lightcraftBinaryPackage = binary;
      };
      modules = [
        (import ./module.nix { kind = "nixos"; })
        nixosStub
        {
          programs.lightcraft = {
            enable = true;
            inherit useBinary;
          };
        }
      ];
    };

  nixosDefault = evalDefault true binaryStub;
  nixosNoBinary = evalDefault true null;
  nixosSourceChosen = evalDefault false binaryStub;

  assertions = [
    {
      what = "useBinary defaults to true";
      ok = nixosDefault.config.programs.lightcraft.useBinary;
    }
    {
      what = "the binary is the default package";
      ok = nixosDefault.config.environment.systemPackages == [ binaryStub ];
    }
    {
      what = "the source build is used without a binary";
      ok = nixosNoBinary.config.environment.systemPackages == [ lightcraft ];
    }
    {
      what = "useBinary = false selects the source build";
      ok = nixosSourceChosen.config.environment.systemPackages == [ lightcraft ];
    }
    {
      what = "nixos installs the package";
      ok = nixos.config.environment.systemPackages == [ lightcraft ];
    }
    {
      what = "nixos mime defaults";
      ok = nixos.config.xdg.mime.defaultApplications == expected;
    }
    {
      what = "nixos palette variable";
      ok = nixos.config.environment.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "nixos mime defaults without setAsDefault";
      ok = nixosPlain.config.xdg.mime.defaultApplications == { };
    }
    {
      what = "nixos writes no settings";
      ok = !builtins.hasAttr "home" nixosPlain.config;
    }
    {
      what = "home-manager installs the package";
      ok = home.config.home.packages == [ lightcraft ];
    }
    {
      what = "home-manager mime defaults";
      ok = home.config.xdg.mimeApps.defaultApplications == expected;
    }
    {
      what = "home-manager mime associations";
      ok = home.config.xdg.mimeApps.associations.added == expected;
    }
    {
      what = "home-manager palette variable";
      ok = home.config.home.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "home-manager writes the overlay";
      ok = builtins.hasAttr settingsFile home.config.home.file;
    }
    {
      what = "home-manager writes no overlay for empty settings";
      ok = !builtins.hasAttr settingsFile homePlain.config.home.file;
    }
    {
      what = "home-manager leaves mimeApps alone without setAsDefault";
      ok = homePlain.config.xdg.mimeApps.enable == false;
    }
  ];

  failed = map (a: a.what) (lib.filter (a: !a.ok) assertions);
in
assert lib.assertMsg (failed == [ ]) "lightcraft modules: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "lightcraft-module-check" { } ''
  grep -q 'thumbSize' ${home.config.home.file.${settingsFile}.source}
  grep -q '260' ${home.config.home.file.${settingsFile}.source}
  touch $out
''
