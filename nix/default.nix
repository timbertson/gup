{ stdenv, lib, fetchurl, python, which, zlib,
	ocaml, findlib,
	ocaml_batteries, cryptokit, extunix, ocaml_lwt
}:
let
	version="0.5.0";
	ocaml_version = (builtins.parseDrvName ocaml.name).version;

	# required only for development (.byte targets)
	libdirs = map ({dep, name}: "${dep}/lib/ocaml/${ocaml_version}/site-lib/${name}") [
		{dep = ocaml_lwt; name = "lwt";}
		{dep = cryptokit; name = "cryptokit";}
		{dep = extunix; name = "extunix";}
	];
	add_ldpath = ''
		export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+:}${lib.concatStringsSep ":" libdirs}";
	'';
in
stdenv.mkDerivation {
	name = "gup-${version}";
	src = fetchurl {
		url = "https://github.com/gfxmonk/gup/archive/version-${version}.tar.gz";
		sha256="0jd3k5lcm7xwm3pmgxq6kp0rchlri8ivc8y445qdz1g2cw7lqw85";
	};
	buildInputs = [
		python which zlib
		ocaml findlib ocaml_batteries cryptokit extunix ocaml_lwt
	];
	shellHook = add_ldpath;
	buildPhase = "make -C ocaml native";
	installPhase = ''
		mkdir $out
		cp -r ocaml/bin $out/bin
	'';
}
