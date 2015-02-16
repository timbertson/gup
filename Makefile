ZEROLOCAL=0install run --not-before=0.2.4 http://gfxmonk.net/dist/0install/0local.xml
PYTHON=python

all: python ocaml

python: python/all
ocaml: ocaml/all
clean: ocaml/clean python/clean

ocaml/%: phony
	make -C ocaml "$$(basename "$@")"

python/%: phony
	make -C python "$$(basename "$@")" "PYTHON=${PYTHON}"

local: gup-test-local.xml gup-local.xml
gup-test-local.xml: gup-test.xml.template
	${ZEROLOCAL} gup-test.xml.template

gup-local.xml: gup.xml.template
	${ZEROLOCAL} gup.xml.template

test: phony
	$(MAKE) unit-test
	$(MAKE) integration-test

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

# Minimal test action: runs full tests, with minimal dependencies.
# This is the only test target that is likely to work on windows
test-min:
	env TEST_COMMAND=test-min make test

# Used for development only
update-windows: phony
	git fetch
	git checkout origin/windows

0compile: gup-local.xml phony
	if [ ! -e 0compile ]; then 0compile setup gup-local.xml 0compile; fi
	cd 0compile && 0compile build --clean

.PHONY: phony
