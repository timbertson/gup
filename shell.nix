{ pkgs ? import <nixpkgs> {} }:
import ./default.nix { ocamlVersion = true; }
