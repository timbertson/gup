{ pkgs  }:
with pkgs;
let
	withExtraDeps = base: extraDeps: base.overrideAttrs (base: {
		buildInputs = base.buildInputs ++ extraDeps;
	});
	python2Impl = import ./default.nix { inherit pkgs; ocamlVersion = false; pythonVersion = 2; };
	python3Impl = import ./default.nix { inherit pkgs; ocamlVersion = false; pythonVersion = 3; };
	ocamlImpl = import ./default.nix { inherit pkgs; ocamlVersion = true; pythonVersion = 3; };
	combinedImpl = withExtraDeps ocamlImpl (python3Impl.buildInputs);
in
# default action gets the combined impl, but specific attrs can be selected for CI
{
	python2 = python2Impl;
	python3 = python3Impl;
	pychecker = pkgs.callPackage ./nix/pychecker.nix {};
	ocaml = ocamlImpl;
	development = combinedImpl;
	opam = stdenv.mkDerivation {
		name = "opam-test";
		buildInputs = [
			opam which git curl unzip python ocaml
			rsync pkgconfig gnum4 gcc ncurses gmp perl
		];
	};
}
