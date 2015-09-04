{ stdenv, lib, python, which
	# TODO: pychecker
}:
{ src, version, meta ? {} }:
stdenv.mkDerivation {
	inherit src meta;
	name = "gup-${version}";
	buildInputs = [ python which ];
	SKIP_PYCHECKER=true;# TODO
	buildPhase = "make python";
	installPhase = ''
		mkdir $out
		cp -r python/bin $out/bin
	'';
}
