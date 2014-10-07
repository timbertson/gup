import os
import errno
import logging
from .log import getLogger
from .var import IS_WINDOWS

__all__ = ['mkdirp', 'get_mtime', 'try_remove', 'samefile', 'rename', 'rmtree', 'lisdir']

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
			rmtree(path)
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

def lisdir(p):
	# NOTE: racey
	return os.path.isdir(p) and not os.path.islink(p)

def rmtree(root):
	"""Like shutil.rmtree, except that we also delete read-only items.
	From ZeroInstall's support/__init__.py:
	# Copyright (C) 2009, Thomas Leonard
	# See the README file for details, or visit http://0install.net.
	"""
	import shutil
	import platform
	if os.path.isfile(root):
		os.chmod(root, 0o700)
		os.remove(root)
	else:
		if platform.system() == 'Windows':
			for main, dirs, files in os.walk(root):
				for i in files + dirs:
					os.chmod(os.path.join(main, i), 0o700)
			os.chmod(root, 0o700)
		else:
			for main, dirs, files in os.walk(root):
				os.chmod(main, 0o700)
		shutil.rmtree(root)

