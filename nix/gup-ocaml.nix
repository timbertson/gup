{ callPackage, stdenv, lib, fetchurl, python,
  which, zlib, ocaml }:
{ src, version, meta ? {} }:
let
  opam2nix = callPackage ./opam2nix-packages.nix {};
  opam_dep_names = [
    "batteries"
    "cryptokit"
    "extunix"
    "lwt"
    "ocamlfind"
  ];
  opam_selections = opam2nix.build {
    packages = opam_dep_names;
  };
  opam_deps = builtins.map (name: builtins.getAttr name opam_selections) opam_dep_names;
  ocaml_version = (builtins.parseDrvName ocaml.name).version;

  # required only for development (.byte targets)
  libdirs = builtins.map ({dep, name}: "${dep}/lib/ocaml/${ocaml_version}/site-lib/${name}") (with opam_selections; [
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
  };
  installPhase = ''
    mkdir $out
    cp -r ocaml/bin $out/bin
    cp -r share $out/share
  '';
}
