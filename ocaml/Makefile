all: bin

release: PREBUILD
	dune build -p gup

unit-test-pre: test/test.exe
integration-test-pre: bin

bin: gup.install

_bin:
	ln -sfn _build/install/default/bin bin

%.install %.exe: PREBUILD
	dune build $@

test: unit-test-pre integration-test-pre phony
	$(MAKE) unit-test
	$(MAKE) integration-test

unit-test: unit-test-pre phony
	../run_tests.py -u

integration-test: integration-test-pre phony
	../run_tests.py -i

PREBUILD: phony version _bin
version: phony gup/version.ml

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
