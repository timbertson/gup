import os
import errno
import logging
from .log import getLogger
log = getLogger(__name__)

__all__ = ['mkdirp', 'get_mtime', 'try_remove']

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
		return int(os.lstat(path).st_mtime * (10 ** 6))
	except OSError as e:
		if e.errno == errno.ENOENT:
			return None
		raise e

def try_remove(path):
	'''Remove a file. Ignore if it doesn't exist'''
	try:
		os.remove(path)
	except OSError as e:
		if e.errno != errno.ENOENT: raise

def close_on_exec(fd, yes):
	import fcntl
	fl = fcntl.fcntl(fd, fcntl.F_GETFD)
	fl &= ~fcntl.FD_CLOEXEC
	if yes:
		fl |= fcntl.FD_CLOEXEC
	fcntl.fcntl(fd, fcntl.F_SETFD, fl)


