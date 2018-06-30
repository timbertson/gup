{ callPackage, stdenv, lib, fetchurl, python, zlib, ncurses }:
{ src, version }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
in
opam2nix.buildOpamPackage {
  name = "gup-${version}";
  inherit src version;
  ocamlAttr = "ocaml-ng.ocamlPackages_4_05.ocaml";
  opamFile = ../gup.opam;
  specs = [ { name = "ounit"; } ];
}
