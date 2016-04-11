{ pkgs ? import <nixpkgs> {}, pythonPackages ? pkgs.pythonPackages, ocamlVersion ? false }:
let
	mocktest = callPackage ./nix/mocktest.nix { inherit pythonPackages; };
	callPackage = pkgs.newScope (pythonPackages // { inherit mocktest; });
	builder = if ocamlVersion
		then callPackage ./nix/gup-ocaml.nix {}
		else callPackage ./nix/gup-python.nix {};
in
builder { src = ./nix/local.tgz; version = "development"; }
