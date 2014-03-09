OCAMLBUILD = $(shell if which rainbow >/dev/null >&2; then echo "rainbow -- ocamlbuild"; else echo "ocamlbuild"; fi)
PIEP=0install run http://gfxmonk.net/dist/0install/piep.xml

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
	../run_tests.py -u
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

clean: phony
	rm -rf _build *.mlpack

%.mlpack: phony
	@ls -1 "$$(basename "$@" ".mlpack")"/ | ${PIEP} 'p.endswith(".ml") | p[:-3] | p[0].upper() + p[1:]' > $@

.PHONY: phony
