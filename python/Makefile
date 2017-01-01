PYTHON=python
ifeq ($(OS),Windows_NT)
	# just used for dependency tracking - always rebuild on windows
	SOURCES:=phony
else
	SOURCES:=../VERSION Makefile $(shell find gup build -type f -name "*.py")
	SOURCES+=gup/version.py
endif

bin: phony bin/gup bin/gup.exe
all: bin

unit-test-pre: phony $(SOURCES)
integration-test-pre: phony bin

unit-test: unit-test-pre phony
	../run_tests.py -u

integration-test: integration-test-pre phony
	../run_tests.py -i

test: unit-test integration-test

bin/gup: $(SOURCES)
	mkdir -p tmp bin
	${PYTHON} ./build/combine_modules.py gup tmp/gup.py
	cp tmp/gup.py bin/gup

GMCS=$(shell which gmcs 2>/dev/null)
bin/gup.exe: gup.cs
	[ -z "$(GMCS)" ] || "$(GMCS)" gup.cs -out:bin/gup.exe

gup/version.py: ../VERSION
	echo "VERSION = \"$$(cat ../VERSION)\"" > $@

clean: phony
	rm gup/*.pyc
	rm -rf tmp bin/gup

.PHONY: phony
