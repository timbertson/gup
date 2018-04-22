{ callPackage, stdenv, lib, fetchurl, pythonPackages, zlib, ncurses }:
{ src, version }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
in
lib.overrideDerivation (opam2nix.buildOpamPackage {
  name = "gup-${version}";
  inherit src version;
  ocamlAttr = "ocaml_4_02";
  opamFile = ../gup.opam;
  extraPackages = [ "ounit" ];
}) (o: {
  buildInputs = (with pythonPackages; [ python whichcraft nose nose_progressive mocktest])
    ++ [ zlib ]
  ;
})
