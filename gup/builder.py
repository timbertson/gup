import tempfile
import os
import stat
from os import path
import errno
import subprocess
import logging

from .gupfile import possible_gup_files, GUPFILE, Gupfile, Gupscript
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
			gupscript = candidate.get_gupscript()
			if gupscript is not None:
				return Target(gupscript)
	return None

class Target(object):
	def __init__(self, gupscript):
		self.gupscript = gupscript
		self.path = self.gupscript.target_path
		self.state = TargetState(self.path)
	
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
		assert os.path.exists(self.gupscript.path)

		basedir = self.gupscript.basedir
		gupscript_path = self.gupscript.path

		# dest may not exist, if a /gup/ directory is in use
		mkdirp(basedir)

		env = os.environ.copy()
		env['GUP_TARGET'] = os.path.abspath(self.path)

		target_relative_to_cwd = os.path.relpath(self.path, var.ROOT_CWD)

		with self.state.perform_build():
			output_file = os.path.abspath(self.state.meta_path('out'))
			MOVED = False
			try:
				args = [os.path.abspath(gupscript_path), output_file, self.gupscript.target]
				log.info(target_relative_to_cwd)
				mtime = get_mtime(self.path)

				exe = guess_executable(gupscript_path)

				if exe is not None:
					args = exe + args

				if var.TRACE:
					log.info(' # %s'% (os.path.abspath(basedir),))
					log.info(' + ' + ' '.join(map(quote, args)))
				else:
					log.debug(' from cwd: %s'% (os.path.abspath(basedir),))
					log.debug('executing: ' + ' '.join(map(quote, args)))

				try:
					ret = self._run_process(args, cwd = basedir, env = env)
				except OSError as e:
					if exe: raise # we only expect errors when we could deduce no executable
					raise SafeError("%s is not executable and has no shebang line" % (gupscript_path,))

				new_mtime = get_mtime(self.path)
				if mtime != new_mtime:
					log.debug("old_mtime=%r, new_mtime=%r" % (mtime, new_mtime))
					if not os.path.isdir(self.path):
						# directories often need to be created directly
						log.warn("%s modified %s directly - this is rarely a good idea" % (gupscript_path, self.path))
				if ret == 0:
					if os.path.exists(output_file):
						os.rename(output_file, self.path)
					MOVED = True
				else:
					log.debug("builder exited with status %s" % (ret,))
					raise TargetFailed(target_relative_to_cwd, ret)
			finally:
				if not MOVED:
					try_remove(output_file)
	
	def _run_process(self, args, cwd, env):
		stderr = None

		if var.RUNNING_TESTS:
			stderr = subprocess.PIPE
			env['GUP_IN_TESTS'] = '1'

		proc = subprocess.Popen(args, cwd = cwd, env = env, stderr = stderr)

		if var.RUNNING_TESTS:
			log = getLogger(__name__ + '.child')
			while True:
				line = proc.stderr.readline().rstrip()
				if not line:
						break
				log.info(line)

		return proc.wait()

def guess_executable(p):
	with open(p) as f:
		line = f.readline(255)
	if not line.startswith('#!'):
		return None
	args = line[2:].strip().split()
	if not args: return None

	bin = args[0]
	if bin.startswith('.'):
		# resolve relative paths relative to containing dir
		bin = args[0] = os.path.join(os.path.dirname(p), args[0])
	if os.path.isabs(bin) and not os.path.exists(bin):
		raise SafeError("No such interpreter: %s" % (os.path.abspath(bin),))
	return args

