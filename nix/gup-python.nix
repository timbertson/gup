{ stdenv, lib, python, nose, whichcraft, mocktest, pychecker ? null }:
{ src, version, meta ? {} }:
let
  usePychecker = pychecker != null;
in
stdenv.mkDerivation {
  inherit src meta;
  name = "gup-${version}";
  buildInputs = [ python whichcraft mocktest nose ] ++ (lib.optional usePychecker pychecker);
  SKIP_PYCHECKER = !usePychecker;
  NOSE_CMD = "${nose}/bin/nosetests";
  buildPhase = "make python";
  testPhase = "make test";
  installPhase = ''
    mkdir $out
    cp -r python/bin $out/bin
  '';
}
