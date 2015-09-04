{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false }:
with pkgs;
let
	ocamlDeps = import ./nix/ocaml-deps.nix { inherit pkgs; };
	builder = if ocamlVersion
		then ocamlDeps.callPackage ./nix/gup-ocaml.nix { inherit (ocamlDeps) extunix; }
		else callPackage ./nix/gup-python.nix {};
in
builder { src = ./nix/local.tgz; version = "development"; }
