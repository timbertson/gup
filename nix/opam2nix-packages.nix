
{ pkgs ? import <nixpkgs> {}}:
with pkgs;
let
	# For development, set OPAM2NIX_DEVEL to your local
	# opam2nix repo path
	devRepo = builtins.getEnv "OPAM2NIX_DEVEL";
	src = fetchgit {
  "url" = "https://github.com/timbertson/opam2nix-packages.git";
  "fetchSubmodules" = false;
  "sha256" = "1317c7vazwziyzdv3vj6cq4frlfqvlg8vgkkisr1sxaljla2l14h";
  "rev" = "0f72a47493e9bc40d2a08dd7eed3af2cb666cfa3";
};
	opam2nix = fetchgit {
  "url" = "https://github.com/timbertson/opam2nix.git";
  "fetchSubmodules" = false;
  "sha256" = "0w13aabqwqvkrxvd98c2fpfran7si2rmqjym0lpdwns8mwghdw1v";
  "rev" = "aaa902104e1a98b6d907420549580537d1feee8e";
};
in
if devRepo != "" then
	let toPath = s: /. + s; in
	callPackage "${devRepo}/nix" {} {
			src = toPath "${devRepo}/nix/local.tgz";
			opam2nix = toPath "${devRepo}/opam2nix/nix/local.tgz";
		}
else callPackage "${src}/nix" {} { inherit src opam2nix; }
