{ callPackage, stdenv, lib, fetchurl, pythonPackages, zlib, ncurses }:
{ src, version, meta ? {}, forceTests ? false }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
  opam2nixParams = {
    packages = import ./opam-dep-names.nix;
    ocamlAttr = "ocaml_4_02";
    overrides = {super, self}: let sels = super.opamSelection; in {
      opamSelection = lib.overrideExisting sels {
        lwt = lib.overrideDerivation sels.lwt (o: {
          # TODO: remove ncurses hack when https://github.com/ocaml/opam-repository/pull/6773 is resolved
          nativeBuildInputs = o.nativeBuildInputs ++ [ ncurses ];
        });
      };
    };
  };

  opam_deps = opam2nix.build opam2nixParams;
  opam_selections = opam2nix.buildPackageSet opam2nixParams;

  # required only for development (.byte targets)
  libdirs = builtins.map ({dep, name}: "${dep}/lib/${name}") (with opam_selections; [
    {dep = lwt; name = "lwt";}
    {dep = cryptokit; name = "cryptokit";}
    {dep = extunix; name = "extunix";}
    {dep = zarith; name = "zarith";}
  ]);
  add_ldpath = ''
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+:}${lib.concatStringsSep ":" libdirs}";
  '';
in
stdenv.mkDerivation {
  name = "gup-${version}";
  inherit src meta;
  buildInputs =
    (with pythonPackages; [ python whichcraft nose nose_progressive mocktest])
    ++ [ zlib ]
    ++ opam_deps
  ;
  shellHook = add_ldpath;
  buildPhase = "make -C ocaml native";
  passthru = {
    selections = opam_selections;
  };
  installPhase = ''
    mkdir -p $out
    cp -r ocaml/bin $out/bin
    cp builders/* $out/bin
    cp -r share $out/share
  '';
}
