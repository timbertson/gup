{ pkgs }:
with pkgs;
let
	callPackage = newScope (ocamlPackages // {
		# `gup` needs subsecond `stat` results
		# these can be dropped once `lwt` is at least
		# 2.5.0, which includes this change.
		ocaml_lwt = lib.overrideDerivation ocamlPackages.ocaml_lwt (o: {
			name = o.name + "-patched";
			patches = (o.patches or []) ++ [
				./0001-lwt_unix-sub-second-precision-for-stat-results.patch
				./0002-lwt_unix-add-configure-check-to-detect-nanosecond-st.patch
			];
		});
	});
	extunix = callPackage ./extunix.nix {};
in
{ inherit callPackage extunix; }
