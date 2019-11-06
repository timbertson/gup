PYTHON=python
GUP_IMPL ?= python

default: impl
	@make ${GUP_IMPL}/all

impl: phony
	@echo "** Note: using implementation: ${GUP_IMPL}"

all: python ocaml

python: python/all
ocaml: ocaml/all
clean: ocaml/clean python/clean

ocaml/%: phony
	@make -C ocaml "$$(basename "$@")"

python/%: phony
	@make -C python "$$(basename "$@")" "PYTHON=${PYTHON}"

test: phony
	$(MAKE) unit-test
	$(MAKE) integration-test

unit-test-pre: phony
unit-test: phony
	$(MAKE) ocaml/unit-test
	$(MAKE) python/unit-test

integration-test-pre: phony ocaml/integration-test-pre python/integration-test-pre
permutation-test: phony integration-test-pre
	${PYTHON} ./run_tests.py -i

integration-test: phony
	$(MAKE) ocaml/integration-test
	$(MAKE) python/integration-test
	$(MAKE) permutation-test

# Used for development only
update-windows: phony
	git fetch
	git checkout origin/windows

# CI targets: invoked from the top-level, will run tests inside nix
ci-python3: phony
	./test/nix-shell -A python --run "make -C python test"

ci-ocaml: phony
	./test/nix-shell -A ocaml --run "make -C ocaml test"

ci-permutation: phony
	./test/nix-shell -A development --run "make permutation-test"

install-base: phony
	[ -n "${DISTDIR}" ]
	mkdir -p "${DISTDIR}/bin"
	mkdir -p "${DISTDIR}/share"
	cp builders/* "${DISTDIR}/bin/"
	cp -a share/* "${DISTDIR}/share/"

install-python: install-base
	make -C python install-bin DISTDIR="${DISTDIR}"

install-ocaml: install-base
	make -C ocaml install-bin DISTDIR="${DISTDIR}"

install: impl
	@make install-${GUP_IMPL}

.PHONY: phony
