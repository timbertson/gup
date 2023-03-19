{ stdenv, pkgs, callPackage, python3Packages, ocaml-ng, opam2nix, gupSrc ? ../. }:
let
	ocamlPackages = ocaml-ng.ocamlPackages_4_08;
	pythonPackages = python3Packages;
	python = pythonPackages.python;

	wrapImpl = drv: drv.overrideAttrs (o: {
		# add test inputs and override source
		buildInputs = (o.buildInputs or []) ++ (with pythonPackages; [ python nose mocktest whichcraft ]);
		src = gupSrc;
	});

	mocktest = callPackage ./mocktest.nix { inherit pythonPackages; };

	opamArgs = {
		inherit (ocamlPackages) ocaml;
		selection = ./opam-selection.nix;
		src = gupSrc;
		override = {selection}: {
			gup = super: super.overrideAttrs (impl: {
				buildInputs = (impl.buildInputs or []) ++ [ selection.ounit ];
			});
		};
	};

	opamSelection = opam2nix.build opamArgs;

	withExtraDeps = base: extraDeps: base.overrideAttrs (base: {
		buildInputs = base.buildInputs ++ extraDeps;
	});

	result = {
		resolveSelection = opam2nix.resolve opamArgs [ ../gup.opam "ounit" ];
		python = wrapImpl (callPackage ./gup-python.nix { inherit python; });
		python-upstream = callPackage ./gup-python.nix {};
		ocaml = wrapImpl (opamSelection.gup);
		development = withExtraDeps result.ocaml (result.python.buildInputs);
		inherit opamSelection;
	};
in
pkgs.lib.extendDerivation true result result.development
