SOURCES:=VERSION Makefile $(shell find gup build -type f -name "*.py")

bin: phony bin/gup
all: bin local

test: unit-test integration-test
unit-test-pre: phony gup-local.xml
integration-test-pre: unit-test-pre bin

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

local: gup-local.xml phony
gup-local.xml: gup.xml.template
	0local gup.xml.template

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin

# dumb alias for local test scripts
unit-test: phony
	./t
integration-test: phony
	./ti

.PHONY: phony
