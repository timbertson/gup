OCAMLBUILD = $(shell if which rainbow >/dev/null 2>&1; then echo "rainbow -- ocamlbuild"; else echo "ocamlbuild"; fi)

all: bin
bin: bin/gup

unit-test-pre: test.byte
integration-test-pre: bin

bin/gup: main.byte phony
	mkdir -p bin
	cp main.byte bin/gup

native: main.native phony
	mkdir -p bin
	cp main.native bin/gup

test: unit-test-pre integration-test-pre phony
	$(MAKE) unit-test
	$(MAKE) integration-test

unit-test: unit-test-pre phony
	../run_tests.py -u

integration-test: integration-test-pre phony
	../run_tests.py -i

test.byte: test/test.byte phony ;
test/test.byte: test.mlpack main.byte

main.byte: gup.mlpack
main.native: gup.mlpack

PREBUILD: phony version
version: phony gup/version.ml

%.byte: PREBUILD
	${OCAMLBUILD} -use-ocamlfind $@

%.native: PREBUILD
	${OCAMLBUILD} -use-ocamlfind $@

%.cmo: PREBUILD
	${OCAMLBUILD} -use-ocamlfind $@

gup/version.ml: ../VERSION
	echo "let version = \"$$(cat ../VERSION)\"" > $@

install: phony native
	[ -n "${DISTDIR}" ]
	mkdir -p "${DISTDIR}/bin"
	cp main.native "${DISTDIR}/bin/gup"
	mkdir -p "${DISTDIR}/share/fish/completions"
	cp -a ../share "${DISTDIR}/"

opam-test: phony
	./test_opam_install.sh

clean: phony
	rm -rf _build *.mlpack *.byte *.native

%.mlpack: phony
	@python ./make-mlpack.py "$$(basename "$@" ".mlpack")"/ "$@"

.PHONY: phony
