# NOTE: the `nixpkgs` version of this file is copied from the upstream repository
# for this package. Please make any changes to https://github.com/timbertson/gup/

{ stdenv, lib, pythonPackages }:
{ src, version, meta ? {}, passthru ? {}, forceTests ? false }:
let
  testInputs = [
    pythonPackages.mocktest or null
    pythonPackages.nose or null
  ];
  pychecker = pythonPackages.pychecker or null;
  usePychecker = forceTests || pychecker != null;
  enableTests = forceTests || (lib.all (dep: dep != null) testInputs);
  basePackage = {
    inherit src meta passthru;
    name = "gup-${version}";
    buildInputs = [ pythonPackages.python ]
      ++ (lib.optionals enableTests testInputs)
      ++ (lib.optional usePychecker pychecker)
    ;
    SKIP_PYCHECKER = !usePychecker;
    buildPhase = "make python";
    installPhase = ''
      mkdir $out
      cp -r python/bin $out/bin
    '';
  };
in
stdenv.mkDerivation (
  basePackage // (if enableTests then {
    NOSE_CMD = "${pythonPackages.nose}/bin/nosetests";
    testPhase = "make test";
  } else {})
)
