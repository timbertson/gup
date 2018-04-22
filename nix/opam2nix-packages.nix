{ pkgs ? import <nixpkgs> {}}:
with pkgs;
let
		src = fetchgit {
			"url" = "https://github.com/timbertson/opam2nix-packages.git";
			"fetchSubmodules" = true;
			"sha256" = "166nxnvlijh5lpnmvjnf7h0yfzbd6ymqgnsbxmzzajbbfzkfn35a";
			"rev" = "71787ddab5b92032637d63bd017dd130764edd92";
		};
		opam2nixSrc = fetchgit {
			"url" = "https://github.com/timbertson/opam2nix.git";
			"fetchSubmodules" = true;
			"sha256" = "03myq1yhcfi0dilzrm43gzyiy3pqxpl2ja0hw8wma5yzxf40hlhj";
			"rev" = "db3228a5c49c184530f11f65a20621567135c327";
		};
	in
	callPackage "${src}/nix" {
		opam2nixBin = callPackage "${opam2nixSrc}/nix" {};
	}
