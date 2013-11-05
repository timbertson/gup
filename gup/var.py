import sys, os

INDENT = os.environ.get('GUP_INDENT', '')
os.environ['GUP_INDENT'] = INDENT + '  '

IS_ROOT = 'GUP_ROOT' not in os.environ
if IS_ROOT: os.environ['GUP_ROOT'] = os.getcwd()

TRACE = os.environ.get('GUP_XTRACE', '0') == '1'
def set_trace():
	global TRACE
	TRACE = True
	os.environ['GUP_XTRACE'] = '1'
