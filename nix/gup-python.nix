{ stdenv, fetchFromGitHub, nix-update-source, lib, python, which, pychecker ? null }:
stdenv.mkDerivation rec {
  version = "0.7.0";
  src = fetchFromGitHub {
    rev = "8b4e22e90db0db4296d3806cb4418fbd7874f32e";
    sha256 = "1zjd76jyb5zc9w3l368723bjmxjl05s096g8ipwncfks1p9hdgf3";
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
