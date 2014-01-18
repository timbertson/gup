all: python ocaml

python: python/all
ocaml: ocaml/all
clean: ocaml/clean python/clean

ocaml/%: phony
	make -C ocaml "$$(basename "$@")"

python/%: phony
	make -C python "$$(basename "$@")"

ocaml/unit-test: phony
	cd ocaml && python ../run_tests.py -u

ocaml/integration-test: phony
	cd python && python ../run_tests.py -i

local: gup-local.xml phony
gup-local.xml: gup.xml.template
	0install run --not-before=0.2.4 http://gfxmonk.net/dist/0install/0local.xml gup.xml.template

test: phony unit-test integration-test

unit-test: phony ocaml/unit-test python/unit-test

integration-test-pre: phony ocaml/integration-test-pre python/integration-test-pre
permutation-test: phony integration-test-pre
	python ./run_tests.py -i

integration-test: phony ocaml/integration-test python/integration-test permutation-test

# Minimal test action: runs full tests, with minimal dependencies.
# This is the only test target that is likely to work on windows
test-min:
	env TEST_COMMAND=test-min make test

# Used for development only
update-windows: phony
	git fetch
	git checkout origin/windows

.PHONY: phony
