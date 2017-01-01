{ pythonPackages, pkgs }:
pythonPackages.buildPythonPackage rec {
  version = "0.7.2";
  name = "mocktest-${version}";

  src = pkgs.fetchgit {
    url = "https://github.com/timbertson/mocktest.git";
    rev = "7addd28581a9e7de0be2b4e19afa3072465bfd5d";
    sha256 = "0zdpasphgmqhxjzlndcmr43cmkfyqpnx7iri20bnyid82vs5r0j1";
  };
}
