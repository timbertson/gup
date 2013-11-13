import os, sys
import logging

# By default, no output colouring.
RED    = ""
GREEN  = ""
YELLOW = ""
BOLD   = ""
PLAIN  = ""

_want_color = os.environ.get('GUP_COLOR', 'auto')
if _want_color == '1' or (
			_want_color == 'auto' and
			sys.stderr.isatty() and
			(os.environ.get('TERM') or 'dumb') != 'dumb'
		):
	# ...use ANSI formatting codes.
	RED    = "\x1b[31m"
	GREEN  = "\x1b[32m"
	YELLOW = "\x1b[33m"
	BOLD   = "\x1b[1m"
	PLAIN  = "\x1b[m"

_colors = {
	logging.INFO: GREEN,
	logging.WARN: YELLOW,
	logging.ERROR: RED,
	logging.CRITICAL: RED,
}

class _ColorFilter(logging.Filter):
	def filter(self, record):
		record.color = _colors.get(record.levelno, '')
		if record.levelno > logging.DEBUG:
			record.bold = BOLD
		else:
			record.bold = ''
		return True

_color_filter = _ColorFilter()

def getLogger(*a):
	log = logging.getLogger(*a)
	log.addFilter(_color_filter)
	return log
