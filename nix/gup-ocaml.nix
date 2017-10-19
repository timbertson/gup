{ callPackage, stdenv, lib, fetchurl, pythonPackages, zlib, ncurses }:
{ src, version, meta ? {}, forceTests ? false }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
in
opam2nix.buildOpamPackage {
  name = "gup-${version}";
  inherit src meta;
  ocamlAttr = "ocaml_4_02";
  buildInputs =
    (with pythonPackages; [ python whichcraft nose nose_progressive mocktest])
    ++ [ zlib ]
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
