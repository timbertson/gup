{ pkgs, callPackage, stdenv, lib, fetchurl, python, zlib, ncurses, pythonImpl ? pkgs.callPackage ./gup-python.nix, opam2nix ? (callPackage ./opam2nix-packages {}) }:
opam2nix.buildOpamPackage rec {
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

  # override ppx_deriving_protobuf with master as of 2019-02-16
  # due to https://github.com/ocaml-ppx/ppx_deriving_protobuf/issues/23
  extraRepos = [ (opam2nix.buildOpamRepo {
    src = pkgs.fetchFromGitHub {
      repo = "ppx_deriving_protobuf";
      owner = "ocaml-ppx";
      rev = "0d75606d604914aa4aff34fbe9919e67a30c00b0";
      sha256 = "11267p6wzm5srm7gndyc93whd1fm60isr9k89d7zsqs9vngibxhl";
    };

    package = "ppx_deriving_protobuf";
    version = "2.6";
  }) ];
}
