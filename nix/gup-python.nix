{ stdenv, fetchFromGitHub, nix-update-source, lib, python, which, pychecker ? null }:
stdenv.mkDerivation rec {
  version = "0.8.1";
  src = fetchFromGitHub {
    rev = "b15680638d5979c133cc87081d15b5d88b7cf161";
    hash = "sha256-K9gXHPzznxUr1+DUx60nZ6AajYc/O/m9hKmxM/ud1RA";
    repo = "gup";
    owner = "timbertson";
  };
  name = "gup-${version}";
  buildInputs = lib.remove null [ python which pychecker ];
  SKIP_PYCHECKER = pychecker == null;
  buildPhase = "make python";
  installPhase = ''
    mkdir $out
    cp -r python/bin $out/bin
  '';
  passthru.updateScript = ''
    set -e
    echo
    cd ${toString ./.}
    ${nix-update-source}/bin/nix-update-source \
      --prompt version \
      --replace-attr version \
      --set owner timbertson \
      --set repo gup \
      --set type fetchFromGitHub \
      --set rev 'version-{version}' \
      --modify-nix default.nix
  '';
  meta = {
    inherit (src.meta) homepage;
    description = "A better make, inspired by djb's redo";
    license = lib.licenses.lgpl2Plus;
    maintainers = [ stdenv.lib.maintainers.timbertson ];
    platforms = stdenv.lib.platforms.all;
  };
}
