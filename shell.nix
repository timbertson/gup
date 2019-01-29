{ pkgs ? import <nixpkgs> {} }:
((pkgs.nix-pin.api {}).callPackage ./ci.nix {}).ocaml
