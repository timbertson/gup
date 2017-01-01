{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false, pythonVersion ? 2 }:
let
	usePython2 = pythonVersion == 2;
	pythonPackages = if usePython2
		then pkgs.python2Packages
		else pkgs.python3Packages;
	python = pythonPackages.python;

	callPackage = pkgs.newScope (pkgs // {
		pythonPackages = pythonPackages // {
			inherit mocktest pychecker;
		};
	});

	mocktest = callPackage ./nix/mocktest.nix {};
	pychecker = pkgs.callPackage ./nix/pychecker.nix {};
	builder = if ocamlVersion
		then callPackage ./nix/gup-ocaml.nix {}
		else callPackage ./nix/gup-python.nix {};
in
builder { src = ./nix/local.tgz; version = "development"; forceTests = true; }
