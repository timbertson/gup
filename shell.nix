{ pkgs ? import <nixpkgs> {} }:
with pkgs;
let
	withExtraDeps = base: extraDeps: lib.overrideDerivation base (base: {
		nativeBuildInputs = base.nativeBuildInputs ++ extraDeps;
		buildInputs = base.buildInputs ++ extraDeps;
	});
	python2Impl = import ./default.nix { ocamlVersion = false; pythonVersion = 2; };
	python3Impl = import ./default.nix { ocamlVersion = false; pythonVersion = 3; };
	ocamlImpl = import ./default.nix { ocamlVersion = true; };
	combinedImpl = withExtraDeps ocamlImpl (python3Impl.nativeBuildInputs);
in
# default action gets the combined impl, but specific attrs can be selected for CI
(lib.addPassthru combinedImpl {
	python2 = python2Impl;
	python3 = python3Impl;
	ocaml = ocamlImpl;
	opam = stdenv.mkDerivation {
		name = "opam-test";
		buildInputs = [opam which git curl unzip ocaml rsync pkgconfig gnum4 gcc ncurses];
	};
})
