MODULES = "$(shell ls -1 gup/ | grep "\.ml$$")"

all: bin
bin: bin/gup

unit-test-pre: test.byte
integration-test-pre: bin
bin/gup: main.byte
	mkdir -p bin
	cp main.byte bin/gup

test: unit-test-pre integration-test-pre phony
	../run_tests.py -u
	../run_tests.py -i

test.byte: test/test.byte phony ;
test/test.byte: test.mlpack gup.cmo

%.byte: phony
	rainbow -- ocamlbuild -use-ocamlfind $@

%.cmo: phony
	rainbow -- ocamlbuild -use-ocamlfind $@

main.byte: gup.mlpack

clean: phony
	rm -rf _build

%.mlpack: phony
	@ls -1 "$$(basename "$@" ".mlpack")"/ | piep 'p.endswith(".ml") | p[:-3] | p[0].upper() + p[1:]' > $@

.PHONY: phony
