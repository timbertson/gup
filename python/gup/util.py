import os
import errno
import logging
import shutil
from .log import getLogger
from .var import IS_WINDOWS

__all__ = ['mkdirp', 'get_mtime', 'try_remove', 'samefile', 'rename']

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
		return int(os.lstat(path).st_mtime * (10 ** 3))
	except OSError as e:
		if e.errno == errno.ENOENT:
			return None
		raise e

def try_remove(path):
	'''
	Remove a file or directory (including contents).
	Ignore if it doesn't exist.
	'''
	try:
		os.remove(path)
	except OSError as e:
		if e.errno == errno.ENOENT:
			pass
		elif e.errno == errno.EISDIR or (
			# Windows gives EACCES when you try to unlink a directory,
			# because ERROR_DIRECTORY_NOT_SUPPORTED ("An operation is
			# not supported on a directory") might accidentally be useful.
			IS_WINDOWS and e.errno == errno.EACCES and os.path.isdir(path)
		):
			shutil.rmtree(path)
		else:
			raise

try:
	samefile = os.path.samefile
except AttributeError:
	# Windows
	def samefile(path1, path2):
		return os.path.normcase(os.path.normpath(path1)) == \
		       os.path.normcase(os.path.normpath(path2))

if IS_WINDOWS:
	def rename(src, dest):
		assert not os.path.isdir(dest)
		if os.path.exists(dest):
			os.remove(dest)
		os.rename(src, dest)
else:
	rename = os.rename
