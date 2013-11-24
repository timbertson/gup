SOURCES:=VERSION Makefile $(shell find gup build -type f -name "*.py")

bin: phony bin/gup
all: bin local

test: unit-test integration-test
unit-test-pre: phony gup-local.xml
integration-test-pre: unit-test-pre bin

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	python ./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

local: gup-local.xml phony
gup-local.xml: gup.xml.template
	0install run --not-before=0.2.4 http://gfxmonk.net/dist/0install/0local.xml gup.xml.template

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin

# dumb alias for local test scripts
unit-test: phony
	./t
integration-test: phony
	./ti

# minimal test action: should work everywhere
test-min: unit-test-pre integration-test-pre
	0install run --command=test-min gup-local.xml
	0install run --command=integration-test-min gup-local.xml

update-windows: phony
	git fetch
	git checkout origin/windows

.PHONY: phony
