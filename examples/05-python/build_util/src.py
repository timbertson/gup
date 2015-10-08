from . import gup
gup.build(__file__)
STAMP_FILE='src/.stamp'

def build_all():
	# build the meta-target which depends on all src/files,
	# and return its contents (one source file per line)
	gup.build(STAMP_FILE)
	with open(STAMP_FILE) as sources:
		return sources.readlines()
