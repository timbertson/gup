{ callPackage, stdenv, lib, fetchurl, python,
  which, zlib }:
{ src, version, meta ? {} }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
  opam_dep_names = import ./opam-dep-names.nix;
  opam_selections_file = opam2nix.select {
    packages = opam_dep_names;
    ocamlAttr = "ocaml_4_02";
  };
  opam_selections = opam2nix.import opam_selections_file {};
  opam_deps = opam2nix.directDependencies opam_dep_names opam_selections;

  # required only for development (.byte targets)
  libdirs = builtins.map ({dep, name}: "${dep}/lib/${name}") (with opam_selections; [
    {dep = lwt; name = "lwt";}
    {dep = cryptokit; name = "cryptokit";}
    {dep = extunix; name = "extunix";}
  ]);
  add_ldpath = ''
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+:}${lib.concatStringsSep ":" libdirs}";
  '';
in
stdenv.mkDerivation {
  name = "gup-${version}";
  inherit src meta;
  buildInputs = [ python which zlib ] ++ opam_deps;
  shellHook = add_ldpath;
  buildPhase = "make -C ocaml native";
  passthru = {
    selections = opam_selections;
    selectionNames = lib.attrNames opam_selections;
    opamDependencyNames = opam_dep_names;
    selectionFile = opam_selections_file;
  };
  installPhase = ''
    mkdir -p $out
    cp -r ocaml/bin $out/bin
    cp -r share $out/share
  '';
}
