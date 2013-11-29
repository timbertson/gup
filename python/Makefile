SOURCES:=../VERSION Makefile $(shell find gup build -type f -name "*.py")

bin: phony bin/gup
all: bin

unit-test-pre: phony
integration-test-pre: phony bin

test: unit-test-pre integration-test-pre phony
	../run_tests.py -u
	../run_tests.py -i

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	python ./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin/gup

.PHONY: phony
