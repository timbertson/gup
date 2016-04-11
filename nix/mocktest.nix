{ pythonPackages, pkgs }:
pythonPackages.buildPythonPackage rec {
  version = "0.7.2";
  name = "mocktest-${version}";

  src = pkgs.fetchgit {
    url = "https://github.com/timbertson/mocktest.git";
    rev = "7addd28581a9e7de0be2b4e19afa3072465bfd5d";
    sha256 = "a53f0255d6fab0301891ce0c61b897a5a28ea3b6f38d67bcc09e2856f538c136";
  };
}
