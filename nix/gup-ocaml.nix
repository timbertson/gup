{ callPackage, stdenv, lib, fetchurl, pythonPackages, zlib, ncurses }:
{ src, version, meta ? {}, forceTests ? false }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
in
opam2nix.buildOpamPackage {
  name = "gup-${version}";
  inherit src meta version;
  ocamlAttr = "ocaml_4_02";
  buildInputs =
    (with pythonPackages; [ python whichcraft nose nose_progressive mocktest])
    ++ [ zlib ]
  ;
  opamFile = ../ocaml/gup.opam;
}
