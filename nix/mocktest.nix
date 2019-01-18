{ pythonPackages, fetchFromGitHub }:
pythonPackages.buildPythonPackage rec {
  version = "0.7.2";
  name = "mocktest-${version}";

  src = fetchFromGitHub {
    repo = "mocktest";
    owner = "timbertson";
    rev = "version-0.7.3";
    sha256 = "0764rgryf6d2cpxjl1kbss7d2gxv053r6q08kdc3qjjjvq99456h";
  };
}

