SOURCES:=VERSION Makefile $(shell find gup build -type f -name "*.py")

bin: phony bin/gup
all: bin local

test: unit-test integration-test
unit-test-pre: phony gup-test-local.xml
integration-test-pre: unit-test-pre bin

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	python ./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

local: gup-test-local.xml phony
gup-test-local.xml: gup-test.xml.template
	0install run --not-before=0.2.4 http://gfxmonk.net/dist/0install/0local.xml gup-test.xml.template

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin/gup

# dumb alias for local test scripts
unit-test: phony
	./t
integration-test: phony
	./ti

# Minimal test action: runs full tests, with minimal dependencies.
# This is the only test target that is likely to work on windows
test-min: unit-test-pre integration-test-pre
	0install run --command=test-min gup-test-local.xml
	0install run --command=integration-test-min gup-test-local.xml

# Used for development only
update-windows: phony
	git fetch
	git checkout origin/windows

.PHONY: phony
