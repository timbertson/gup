{ pkgs ? import <nixpkgs> {}}:
with pkgs;
let
	src = fetchgit {
		fetchSubmodules = false;
		url = "https://github.com/timbertson/opam2nix-packages.git";
		rev = "d30f9bfde144a29d16248b7369d609268d6280ad";
		sha256 = "84b9941377f7b8b317beffd70ed0e7b50b992f6340cac6a514208ee6924210a1";
	};

	# We could leave this out and just use `fetchSubmodules` above,
	# but that leads to mass-rebuilds every time the repo changes
	# (rather than only when opam2nix is updated)
	opam2nix = fetchgit {
		url = "https://github.com/timbertson/opam2nix.git";
		rev = "6f4ed44162b97a475c4302c74781a4e45495b5fa";
		sha256 = "ef1df81e3231654bb2185c7fc2434c777a52c0ac5e0c5188186842941d12c2b3";
	};
in
callPackage "${src}/nix" {} { inherit src opam2nix; }
