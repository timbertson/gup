{ callPackage, stdenv, lib, fetchurl, python,
  which, zlib, ncurses }:
{ src, version, meta ? {} }:
let
  opam2nix =
    let
      dev_repo = builtins.getEnv "OPAM2NIX_DEVEL";
      toPath = s: /. + s;
      in if dev_repo != ""
        then callPackage "${dev_repo}/nix" {} {
            src = toPath "${dev_repo}/nix/local.tgz";
            opam2nix = toPath "${dev_repo}/opam2nix/nix/local.tgz";
          }
        else callPackage ./opam2nix-packages.nix {};

  opam_dep_names = import ./opam-dep-names.nix;
  opam_selections_file = opam2nix.select {
    packages = opam_dep_names;
    ocamlAttr = "ocaml_4_02";
  };
  opam_selections = opam2nix.import opam_selections_file {
    overrides = {super, self}: let sels = super.opamSelection; in {
      opamSelection = lib.overrideExisting sels {
        lwt = lib.overrideDerivation sels.lwt (o: {
          # TODO: remove ncurses hack when https://github.com/ocaml/opam-repository/pull/6773 is resolved
          nativeBuildInputs = o.nativeBuildInputs ++ [ ncurses ];
        });
      };
    };
  };
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
    opam2nix = opam2nix.opam2nix;
    selectionFile = opam_selections_file;
  };
  installPhase = ''
    mkdir -p $out
    cp -r ocaml/bin $out/bin
    cp -r share $out/share
  '';
}
