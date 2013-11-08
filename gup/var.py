from __future__ import print_function
import sys, os

INDENT = os.environ.get('GUP_INDENT', '')
os.environ['GUP_INDENT'] = INDENT + '  '

IS_ROOT = 'GUP_ROOT' not in os.environ
if IS_ROOT: os.environ['GUP_ROOT'] = os.getcwd()

ROOT_CWD = os.environ['GUP_ROOT']

TRACE = os.environ.get('GUP_XTRACE', '0') == '1'
def set_trace():
	global TRACE
	TRACE = True
	os.environ['GUP_XTRACE'] = '1'

DEFAULT_VERBOSITY = int(os.environ.get('GUP_VERBOSE', '0'))
def set_verbosity(val):
	os.environ['GUP_VERBOSE'] = str(val)

RUNNING_TESTS = os.environ.get('GUP_IN_TESTS', '0') == '1'
