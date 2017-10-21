OCAMLBUILD = $(shell if which rainbow >/dev/null 2>&1; then echo "rainbow -- ocamlbuild"; else echo "ocamlbuild"; fi)

all: bin

unit-test-pre: test/test.exe
integration-test-pre: bin

bin: gup.install
	ln -sfn _build/install/default/bin bin

%.install: PREBUILD
	jbuilder build $@

test: unit-test-pre integration-test-pre phony
	$(MAKE) unit-test
	$(MAKE) integration-test

unit-test: unit-test-pre phony
	../run_tests.py -u

integration-test: integration-test-pre phony
	../run_tests.py -i

PREBUILD: phony version
version: phony gup/version.ml

%.exe: PREBUILD
	jbuilder build $@

gup/version.ml: ../VERSION
	echo "let version = \"$$(cat ../VERSION)\"" > $@

install-bin: phony gup.install
	[ -n "${DISTDIR}" ]
	cp -r --dereference bin/* "${DISTDIR}/bin/"

opam-test: phony
	./test_opam_install.sh

clean: phony
	rm -rf _build *.exe *.install

.PHONY: phony
