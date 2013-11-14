bin:
	mkdir -p tmp build/bin
	./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py build/bin

gup-local.xml: gup.xml.template
	0local gup.xml.template
