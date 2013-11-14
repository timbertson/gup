all: build/bin phony

build/bin: phony
	git clean -fdx tmp build/bin
	mkdir -p tmp build/bin
	./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py build/bin/gup

local: gup-local.xml phony
gup-local.xml: gup.xml.template
	0local gup.xml.template

.PHONY: phony
