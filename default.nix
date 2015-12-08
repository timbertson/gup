{ pkgs ? import <nixpkgs> {}, ocamlVersion ? false }:
with pkgs;
let
	builder = if ocamlVersion
		then callPackage ./nix/gup-ocaml.nix {}
		else callPackage ./nix/gup-python.nix {};
in
builder { src = ./nix/local.tgz; version = "development"; }
