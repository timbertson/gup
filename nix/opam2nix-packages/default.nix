let fetch = pkgs: srcJson: (pkgs.nix-update-source.fetch srcJson).src; in
{
	pkgs ? import <nixpkgs> {},
	opam2nixBin ? pkgs.callPackage "${fetch pkgs ./src-opam2nix.json}/nix" {},
	opamRepository ? fetch pkgs ./src-opam-repository.json,
}:
pkgs.callPackage "${fetch pkgs ./src.json}/nix" { inherit opam2nixBin opamRepository; }
