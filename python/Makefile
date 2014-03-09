SOURCES:=../VERSION Makefile $(shell find gup build -type f -name "*.py")
SOURCES+=gup/version.py

bin: phony bin/gup
all: bin

unit-test-pre: phony
integration-test-pre: phony bin

unit-test: unit-test-pre phony
	../run_tests.py -u

integration-test: integration-test-pre phony
	../run_tests.py -i

test: unit-test integration-test

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	python ./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

gup/version.py: ../VERSION
	echo "VERSION = \"$$(cat ../VERSION)\"" > $@

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin/gup

.PHONY: phony
