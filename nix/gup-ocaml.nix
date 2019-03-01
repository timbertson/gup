{ callPackage, stdenv, lib, fetchurl, python, zlib, ncurses, pythonImpl, opam2nix ? (callPackage ./opam2nix-packages {}) }:
opam2nix.buildOpamPackage rec {
  inherit (pythonImpl.drvAttrs) src version;
  name = "gup-${version}";
  ocamlAttr = "ocaml-ng.ocamlPackages_4_06.ocaml";
  opamFile = ../gup.opam;
  specs = [ { name = "ounit"; } { name = "merlin"; } ];
}
