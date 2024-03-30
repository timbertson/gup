{ stdenv, pkgs, callPackage, python3Packages, ocaml-ng, opam2nix, self }:
let
	ocamlPackages = ocaml-ng.ocamlPackages_4_14;
	pythonPackages = python3Packages;
	python = pythonPackages.python;

	wrapImpl = drv: drv.overrideAttrs (o: {
		# add test inputs and override source
		buildInputs = (o.buildInputs or []) ++ (with pythonPackages; [ python nose mocktest whichcraft ]);
		src = self;
	});

	mocktest = callPackage ./mocktest.nix { inherit pythonPackages; };
	pychecker = pkgs.callPackage ./pychecker.nix {};

	opamArgs = {
		inherit (ocamlPackages) ocaml;
		selection = ./opam-selection.nix;
		src = self;
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
		pychecker = pkgs.callPackage ./nix/pychecker.nix {};
		resolveSelection = opam2nix.resolve opamArgs [
			../gup.opam
			"ounit"
			"ocaml-lsp-server"
			"utop"
		];
		python = wrapImpl (callPackage ./gup-python.nix { inherit python pychecker; });
		ocaml = wrapImpl (opamSelection.gup);
		development = withExtraDeps result.ocaml (result.python.buildInputs ++ [
			opamSelection.ocaml-lsp-server
			opamSelection.utop
		]);
		inherit opamSelection;
	};
in
result.development.overrideAttrs (o: {
	passthru = (o.passthru or {}) // result;
})
