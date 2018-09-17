{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false, pythonVersion ? 3 }:
let
	usePython2 = pythonVersion == 2;
	pythonPackages = if usePython2
		then pkgs.python2Packages
		else pkgs.python3Packages;
	python = pythonPackages.python;

	addTestDeps = pythonPackages: drv: drv.overrideAttrs (o: {
		buildInputs = o.buildInputs ++ (with pythonPackages; [ python nose nose_progressive mocktest whichcraft ]);
	});

	callPackage = pkgs.callPackage;

	mocktest = callPackage ./nix/mocktest.nix { inherit pythonPackages; };
	pychecker = pkgs.callPackage ./nix/pychecker.nix {};

	pythonImpl = addTestDeps pythonPackages (callPackage ./nix/gup-python.nix { inherit python pychecker; });
	ocamlImpl = addTestDeps pkgs.python2Packages (callPackage ./nix/gup-ocaml.nix { inherit python; });

in
if ocamlVersion then ocamlImpl else pythonImpl
