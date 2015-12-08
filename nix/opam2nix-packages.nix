{ pkgs ? import <nixpkgs> {}}:
with pkgs;
let
	dev_repo = builtins.getEnv "OPAM2NIX_DEVEL";
	toPath = s: /. + s;
	in if dev_repo != ""
		then callPackage "${dev_repo}/nix" {} {
				src = toPath "${dev_repo}/nix/local.tgz";
				opam2nix = toPath "${dev_repo}/opam2nix/nix/local.tgz";
			}
		else let
			src = fetchgit {
				fetchSubmodules = false;
				url = "https://github.com/timbertson/opam2nix-packages.git";
				rev = "6e3dc7884f80f5fad8bd329cbeaeaeced45cc3c4";
				sha256 = "65f7c8d3f789c34ed1467c5567f85bf04a089395dcebd988f96a285bfe539e6a";
			};

			# We could leave this out and just use `fetchSubmodules` above,
			# but that leads to mass-rebuilds every time the repo changes
			# (rather than only when opam2nix is updated)
			opam2nix = fetchgit {
				url = "https://github.com/timbertson/opam2nix.git";
				rev = "87f642c0279545db8da33377d80d11a30ee551cc";
				sha256 = "4e837675b64f4ee6b0f597a7e11f54c88087d63e30a60addf1ba1cc6c5560d08";
			};
		in callPackage "${src}/nix" {} { inherit src opam2nix; }


