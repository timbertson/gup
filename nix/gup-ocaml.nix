{ pkgs, callPackage, stdenv, lib, fetchurl, python, zlib, ncurses,
  pythonImpl ? pkgs.callPackage ./gup-python.nix {},
  opam2nix
}:
opam2nix.build rec {
  inherit (pythonImpl.drvAttrs) src version;
  name = "gup-${version}";
  ocamlAttr = "ocaml-ng.ocamlPackages_4_06.ocaml";
  opamFile = ../gup.opam;
  specs = [
    # TODO: limit to shell
    { name = "ounit"; }
    { name = "merlin"; }
    { name = "utop"; }
  ];
}
