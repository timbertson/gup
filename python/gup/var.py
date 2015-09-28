from __future__ import print_function
import os, sys
import time

IS_WINDOWS = sys.platform.startswith('win')

PY3 = sys.version_info >= (3,0)

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

XTRACE = os.environ.get('GUP_XTRACE', '0') == '1'
def set_trace():
	global XTRACE
	XTRACE = True
	os.environ['GUP_XTRACE'] = '1'

DEFAULT_VERBOSITY = int(os.environ.get('GUP_VERBOSE', '0'))
def set_verbosity(val):
	os.environ['GUP_VERBOSE'] = str(val)

def set_keep_failed_outputs():
	os.environ['GUP_KEEP_FAILED'] = '1'

def keep_failed_outputs():
	return os.environ.get('GUP_KEEP_FAILED', '0') == '1'
