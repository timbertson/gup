{ pkgs ? import <nixpkgs> {}, pythonPackages ? pkgs.pythonPackages }:
let
attrs = rec {
  version = "0.8.19";
  name = "pychecker-${version}";

  src = pkgs.fetchzip {
    url = "https://sourceforge.net/projects/pychecker/files/pychecker/0.8.19/pychecker-0.8.19.tar.gz";
    sha256 = "0318gxzhfa45bnrqqw1q7wqw0bkgv3zfjn33c57x1cixvn2g7bfb";
  };

  # pychecker tries to be fancy about detecting its installation
  # prefix, but concludes it's being installed to `/`
  postFixup = ''
    sed -i -e "s| /pychecker/| $out/${pythonPackages.python.sitePackages}/pychecker/|" $out/bin/pychecker
  '';
};
lib = pythonPackages.buildPythonApplication attrs;
in
# Wrap the lib in a derivation exposing only `bin/`, so that
# the tool can be used in a python3 project
pkgs.stdenv.mkDerivation {
  inherit (attrs) name version;
  buildCommand = ''
    mkdir -p $out
    ln -sfn ${lib}/bin $out/bin
  '';
}


