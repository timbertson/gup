{ pkgs ? import <nixpkgs> {} }:
(pkgs.callPackage ./ci.nix {}).combinedImpl
