{ pkgs ? import <nixpkgs> {} }:
with pkgs;
let
	pythonImpl = import ./default.nix { ocamlVersion = false; };
	ocamlImpl = import ./default.nix { ocamlVersion = true; };
in
lib.overrideDerivation (ocamlImpl) (super:
let
	extraDeps = [pythonPackages.nose_progressive];
in
{
	NOSE_ARGS = "--with-progressive";
	nativeBuildInputs = super.nativeBuildInputs ++ pythonImpl.nativeBuildInputs ++ extraDeps;
	buildInputs = super.buildInputs ++ pythonImpl.buildInputs ++ extraDeps;
})
