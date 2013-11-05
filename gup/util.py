import os
import errno
import logging
from .log import getLogger
log = getLogger(__name__)

__all__ = ['mkdirp', 'get_mtime']

def mkdirp(p):
	try:
		os.makedirs(p)
	except OSError as e:
		if e.errno != errno.EEXIST: raise

def get_mtime(path):
	'''
	Note: we return a microsecond int as this serializes to / from strings better
	'''
	try:
		return int(os.stat(path).st_mtime * (10 ** 6))
	except OSError as e:
		if e.errno == errno.ENOENT:
			return None
		raise e

