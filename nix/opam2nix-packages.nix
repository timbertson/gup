{ pkgs ? import <nixpkgs> {}}:
with pkgs;
let
		src = fetchFromGitHub {
			"owner" = "timbertson";
			"repo" = "opam2nix-packages";
			"sha256" = "060h422rbvbh2mkmfp04rljssxp9ppf8g38jyl6dvby2r8if9fb9";
			"rev" = "7d30aa408d91467f78498ed21999d23fca37500e";
		};
		opam2nixSrc = fetchFromGitHub {
			"owner" = "timbertson";
			"repo" = "opam2nix";
			"sha256" = "1khq1b0c7ry8854nwl0qkfq0kddf4g49xmj1yp2bifk8kh2waqb7";
			"rev" = "version-0.3.1";
		};
		opam2nixBin = callPackage "${opam2nixSrc}/nix" {};
	in
	callPackage "${src}/nix" { inherit opam2nixBin; }

