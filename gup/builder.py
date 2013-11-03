import tempfile
import os
import stat
from os import path
import errno
import subprocess
import logging
log = logging.getLogger(__name__)

from .gupfile import possible_gup_files, GUPFILE, Gupfile
from . import output
from .error import *

def prepare_build(p):
	'''
	Prepares `path` for building. This includes:
	- taking a lock of its metadata
	- traversing all .gup files and Gupfiles
	- checking all Gupfiles encountered to see if they are candidates
	  for building this path
	- returns None if the file is not buildable, a Target object otherwise
	'''
	target = Target(p)
	for (base, gupfilename) in possible_gup_files(p):
		guppath = path.join(base, gupfilename)
		if path.exists(guppath):
			if gupfilename == GUPFILE:
				gupfile = Gupfile(guppath)
				builder = gupfile.builder(p)
				if builder is not None:
					target.set_builder(builder)
					return target
			else:
				# direct gupfile - must be buildable
				target.set_builder(guppath)
				return target
	return None

def _get_mtime(path):
	try:
		return os.stat(path).st_mtime
	except OSError as e:
		if e.errno == errno.ENOENT:
			return None
		raise e

class Target(object):
	def __init__(self, p):
		self.path = p
		self.gupscript = None
	
	def __repr__(self):
		return 'Target(%r)' % (self.path,)
	
	def set_builder(self, b):
		assert self.gupscript is None
		self.gupscript = os.path.abspath(b)
	
	def add_dependency(self, d):
		log.warn("TODO: %s depends on %s" % (self.path, d))
	
	def build(self, force):
		# XXX: force
		assert self.gupscript is not None
		basedir = path.dirname(self.path) or '.'
		with tempfile.NamedTemporaryFile(prefix='.gup-tmp-', dir=basedir, delete=False) as temp:
			MOVED = False
			try:
				args = [self.gupscript, temp.name, self.path]
				output.building_target(self.path)
				mtime = _get_mtime(self.path)
				try:
					proc = subprocess.Popen(args, cwd = basedir)
				except OSError as e:
					if e.errno != errno.EACCES: raise e
					# not executable - read shebang ourselves
					args = guess_executable(self.gupscript) + args
					proc = subprocess.Popen(args, cwd = basedir)
				finally:
					output.xtrace(args)
				ret = proc.wait()
				new_mtime = _get_mtime(self.path)
				if mtime != new_mtime:
					log.debug("old_mtime=%r, new_mtime=%r" % (mtime, new_mtime))
					log.warn("%s modified %s directly - this is rarely a good idea" % (self.gupscript, self.path))
				if ret == 0:
					os.rename(temp.name, self.path)
					MOVED = True
				else:
					log.debug("builder exited with status %s" % (ret,))
					raise TargetFailed(self, ret)
			finally:
				if not MOVED:
					os.remove(temp.name)

def guess_executable(p):
	with open(p) as f:
		line = f.readline(255)
	if not line.startswith('#!'):
		raise SafeError("%s is not executable and has no shebang line" % (p,))
	return line[2:].strip().split()

