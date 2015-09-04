{ stdenv, lib, python, which, pychecker ? null }:
{ src, version, meta ? {} }:
stdenv.mkDerivation {
	inherit src meta;
	name = "gup-${version}";
	buildInputs = lib.remove null [ python which pychecker ];
	SKIP_PYCHECKER = pychecker == null;
	buildPhase = "make python";
	installPhase = ''
		mkdir $out
		cp -r python/bin $out/bin
	'';
}
