{ pkgs ? import <nixpkgs> {} }:
with pkgs;
let
	pythonPackages = if builtins.getEnv("GUP_PYTHON_VERSION") == "3"
		then pkgs.python3Packages
		else pkgs.python2Packages;
	useProgressive = !pythonPackages.isPy3k;
	pythonImpl = import ./default.nix { ocamlVersion = false; inherit pythonPackages; };
	ocamlImpl = import ./default.nix { ocamlVersion = true; inherit pythonPackages; };
	
in
lib.overrideDerivation (ocamlImpl) (super:
let
	extraDeps = (lib.optional (useProgressive) pythonPackages.nose_progressive);
in
{
	NOSE_CMD = "${pythonPackages.nose}/bin/nosetests${
		if useProgressive then " --with-progressive" else ""
	}";
	SKIP_PYCHECKER = false; # hacky
	nativeBuildInputs = super.nativeBuildInputs ++ pythonImpl.nativeBuildInputs ++ extraDeps;
	buildInputs = super.buildInputs ++ pythonImpl.buildInputs ++ extraDeps;
})
