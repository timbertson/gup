{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false }:
let
	usePython2 = builtins.getEnv("GUP_PYTHON_VERSION") == "2";
	pythonPackages = if usePython2
		then pkgs.python2Packages
		else pkgs.python3Packages;
	python = pythonPackages.python;

	pythonParams = {
		pythonPackages = pythonPackages // {
			inherit mocktest pychecker;
		};
	};

	mocktest = pkgs.callPackage ./nix/mocktest.nix pythonParams;
	pychecker = pkgs.callPackage ./nix/mocktest.nix pythonParams;

	builder = if ocamlVersion
		then pkgs.callPackage ./nix/gup-ocaml.nix {}
		else pkgs.callPackage ./nix/gup-python.nix pythonParams;
in
builder { src = ./nix/local.tgz; version = "development"; forceTests = true; }
