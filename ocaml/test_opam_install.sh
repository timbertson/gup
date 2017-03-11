#!/bin/bash
set -eux

if [ -z "${IN_NIX_SHELL:-}" ] && which nix-shell >/dev/null 2>&1; then
	echo "Running inside nix-shell..."
	exec env IN_NIX_SHELL=1 nix-shell -p zlib opam --run "$0" "$@"
fi

if ! which opam >/dev/null 2>&1; then
	echo 'Error: `opam` required' >&2
	exit 1
fi

here="$(dirname "$(readlink -f "$0")")"
cd "$here/.."

opam lint gup.opam

function cleanup() {
	status="$?"
	if [ "$status" != 0 -a 1 = "${SHELL_ON_ERROR:-}" ]; then
		opam config exec --switch=gup-test -- bash -i
	fi
	if [ -n "${tempdir:-}" ]; then
		if [ 1 = "${KEEP_OPAM:-}" ]; then
			echo "NOTE: not cleaning up. To re-use:"
			echo "  export SCRATCH_OPAM=$tempdir"
		else
			rm -rf "$tempdir"
		fi
	fi

	exit "$status"
}
trap "cleanup" EXIT

if [ -n "${SCRATCH_OPAM:-}" ]; then
	# OPAMYES=1 opam switch system
	# OPAMYES=1 opam switch remove gup-test || true
	OPAMYES=1 opam uninstall gup || true
	export OPAMROOT="$SCRATCH_OPAM"
else
	tempdir="$(mktemp -d)"
	export OPAMROOT="$tempdir"
	opam init --no-setup
fi

unset OCAMLPATH OCAMLFIND_DESTDIR
BASE_SWITCH="4.02.3"
# BASE_SWITCH="system" # quicker

export OPAMYES=1
opam switch list | grep -q gup-test || opam switch install gup-test --alias-of "$BASE_SWITCH"
unset OPAMYES

opam config exec --switch=gup-test -- bash -eux <<"EOF"
	export OPAMYES=1
	opam pin add --kind git --no-action "$(pwd)"
	opam install gup
	opam list
EOF
