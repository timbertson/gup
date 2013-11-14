#!/usr/bin/env python
# (this file appears first in build/bin/gup)
from __future__ import print_function
import sys, os
def _check_PATH():
	progname = sys.argv[0]
	if os.path.sep in progname and os.environ.get('GUP_IN_PATH', '0') != '1':
		# gup may have been run as a relative / absolute script - check
		# whether our directory is in $PATH
		path_entries = os.environ.get('PATH', '').split(os.pathsep)
		here = os.path.dirname(__file__)
		for entry in path_entries:
			if not entry: continue
			try:
				if os.path.samefile(entry, here):
					# ok, we're in path
					break
			except OSError: pass
		else:
			# not found
			os.environ['PATH'] = os.pathsep.join([here] + path_entries)

		# don't bother checking next time
		os.environ['GUP_IN_PATH'] = '1'
_check_PATH()
