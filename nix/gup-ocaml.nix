{ callPackage, stdenv, lib, fetchurl, python, zlib, ncurses, opam2nix ? (callPackage ./opam2nix-packages {}) }:
let pythonImpl = callPackage ./gup-python.nix {}; in
opam2nix.buildOpamPackage rec {
  inherit (pythonImpl.drvAttrs) src version;
  name = "gup-${version}";
  ocamlAttr = "ocaml-ng.ocamlPackages_4_05.ocaml";
  opamFile = ../gup.opam;
  specs = [ { name = "ounit"; } ];
}
