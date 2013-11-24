from __future__ import print_function
import os, sys
import time

IS_WINDOWS = sys.platform.startswith('win')

INDENT = os.environ.get('GUP_INDENT', '')
os.environ['GUP_INDENT'] = INDENT + '  '

def init_root(is_root):
	global IS_ROOT, ROOT_CWD, RUN_ID
	IS_ROOT = is_root
	if is_root:
		RUN_ID = os.environ['GUP_RUNID'] = str(int(time.time() * 1000))
		ROOT_CWD = os.environ['GUP_ROOT'] = os.getcwd()
	else:
		ROOT_CWD = os.environ['GUP_ROOT']
		assert 'GUP_RUNID' in os.environ, "GUP_ROOT is set (to %s), but not GUP_RUNID" % (ROOT_CWD)
		RUN_ID = os.environ['GUP_RUNID']

init_root('GUP_ROOT' not in os.environ)

TRACE = os.environ.get('GUP_XTRACE', '0') == '1'
def set_trace():
	global TRACE
	TRACE = True
	os.environ['GUP_XTRACE'] = '1'

DEFAULT_VERBOSITY = int(os.environ.get('GUP_VERBOSE', '0'))
def set_verbosity(val):
	os.environ['GUP_VERBOSE'] = str(val)
