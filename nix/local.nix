{ pkgs ? import <nixpkgs> {}}:
let
	sources = import ./sources.nix { inherit pkgs; sourcesFile = ./sources.json; };
	opam2nix = pkgs.callPackage sources.opam2nix {};
in
pkgs.callPackage ./default.nix {
	inherit opam2nix;
	gupSrc = sources.local { url = ../.; };
}
