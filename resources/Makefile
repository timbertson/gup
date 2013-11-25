# Modify this to point to your repository-local
# gup exectable
GUP=tools/gup

# Default to building the `all` target
all: phony ${GUP}
	@+${GUP} all

# Catch-all target which delgates to `gup`
%: phony ${GUP}
	@+${GUP} $@

# Remove explicit Makefile rule
Makefile: ;

# Always rebuild gup targets
.PHONY: phony
