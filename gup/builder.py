import tempfile
import os
import stat
from os import path
import errno
import subprocess
import logging

from .gupfile import possible_gup_files, GUPFILE, Gupfile
from .error import *
from .util import *
from .state import TargetState
from .log import getLogger
from . import var
log = getLogger(__name__)

try:
	from pipes import quote
except ImportError:
	from shlex import quote

def prepare_build(p):
	'''
	Prepares `path` for building. This includes:
	- taking a lock of its metadata
	- traversing all .gup files and Gupfiles
	- checking all Gupfiles encountered to see if they are candidates
	  for building this path
	- returns None if the file is not buildable, a Target object otherwise
	'''
	for candidate in possible_gup_files(p):
		guppath = candidate.guppath
		# log.debug("gupfile candidate: %s" % (guppath,))
		if path.exists(guppath):
			log.debug("gupfile candidate exists: %s" % (guppath,))
			if candidate.indirect:
				builder = Gupfile(guppath).builder(candidate.target)
				if builder is not None:
					return Target(p, builder)
			else:
				# direct gupfile - must be buildable
				return Target(p, guppath)
	return None

class Target(object):
	def __init__(self, p, gupscript=None):
		self.path = p
		self.gupscript = gupscript
		self.state = TargetState(p)
	
	def __repr__(self):
		return 'Target(%r)' % (self.path,)
	
	def is_dirty(self):
		deps = self.state.deps()
		log.debug("Loaded serialized state: %r" % (deps,))
		if deps is None:
			return True
		return deps.is_dirty()

	def build(self, force):
		# XXX: force
		assert self.gupscript is not None

		basedir = path.dirname(self.path) or '.'

		# dest may not exist, if a /gup/ directory is in use
		mkdirp(basedir)

		env = os.environ.copy()
		env['GUP_TARGET'] = os.path.abspath(self.path)

		gupscript = os.path.abspath(self.gupscript)

		with self.state.perform_build():
			output_file = os.path.abspath(self.state.meta_path('out'))
			MOVED = False
			# with open(output_file, 'w'): pass
			try:
				args = [gupscript, output_file, self.path]
				log.info(self.path)
				mtime = get_mtime(self.path)
				try:
					proc = subprocess.Popen(args, cwd = basedir, env = env)
				except OSError as e:
					if e.errno != errno.EACCES: raise
					# not executable - read shebang ourselves
					args = guess_executable(gupscript) + args
					proc = subprocess.Popen(args, cwd = basedir, env = env)
				finally:
					if var.TRACE:
						log.info(' + ' + ' '.join(map(quote, args)))
				ret = proc.wait()
				new_mtime = get_mtime(self.path)
				if mtime != new_mtime:
					log.debug("old_mtime=%r, new_mtime=%r" % (mtime, new_mtime))
					log.warn("%s modified %s directly - this is rarely a good idea" % (gupscript, self.path))
				if ret == 0:
					if os.path.exists(output_file):
						os.rename(output_file, self.path)
					MOVED = True
				else:
					log.debug("builder exited with status %s" % (ret,))
					raise TargetFailed(self, ret)
			finally:
				if not MOVED:
					try_remove(output_file)

def guess_executable(p):
	with open(p) as f:
		line = f.readline(255)
	if not line.startswith('#!'):
		raise SafeError("%s is not executable and has no shebang line" % (p,))
	return line[2:].strip().split()

