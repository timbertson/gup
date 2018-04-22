{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false, pythonVersion ? 3 }:
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

	pythonImpl = callPackage ./nix/gup-python.nix {};
	src = pythonImpl.drvAttrs.src;

	ocamlImpl = (callPackage ./nix/gup-ocaml.nix {}) {
		inherit (pythonImpl.drvAttrs) src version;
	};

in
if ocamlVersion then ocamlImpl else pythonImpl
