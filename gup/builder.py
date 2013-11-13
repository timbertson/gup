from __future__ import print_function
import tempfile
import os
import stat
from os import path
import errno
import subprocess
import logging
import shutil

from .gupfile import Builder
from .error import *
from .util import *
from .state import TargetState
from .log import getLogger
from . import var
from . import jwack
log = getLogger(__name__)

try:
	from pipes import quote
except ImportError:
	from shlex import quote

def prepare_build(p):
	builder = Builder.for_target(p)
	log.debug('prepare_build(%r) -> %r' % (p, builder))
	if builder is not None:
		return Target(builder)
	return None

def build_all(targets, update):
	# XXX make parallel
	return any([target.build(update = update) for target in targets])

def _is_dirty(state):
	'''
	Returns whether the dependency is dirty.
	Builds any targets required to check dirtiness
	'''
	deps = state.deps()
	builder = Builder.for_target(state.path)

	if deps is None:
		if builder is None:
			# not a target
			return False
		else:
			log.debug("DIRTY: %s (is buildable but has no stored deps)", state.path)
			return True

	if deps.already_built():
		log.warn("CLEAN: %s has already been built in this invocation", state.path)
		return False

	dirty = deps.is_dirty(builder, built = False)

	if dirty is True:
		log.debug("deps.is_dirty(%r) -> True", state.path)
		return True

	if dirty is False:
		# not directly dirty - recurse children
		for path in deps.children():
			log.debug("Recursing over dependency: %s", path)
			child = TargetState(path)
			if _is_dirty(child):
				log.debug("_is_dirty(%r) -> True", child.path)
				return True
		return False

	assert isinstance(dirty, list)
	for target in dirty:
		log.debug("MAYBE_DIRTY: %s (unknown state - building it to find out)", target)
		target = prepare_build(target.path)
		if target is None:
			log.debug("%s turned out not to be a target - skipping", target)
			continue
		target.build(update=True)

	dirty = deps.is_dirty(builder, built = True)
	assert dirty in (True, False)
	log.debug("after rebuilding unknown targets, deps.is_dirty(%r) -> %r", state.path, dirty)
	return dirty

class Target(object):
	def __init__(self, builder):
		self.builder = builder
		self.path = self.builder.target_path
		self.state = TargetState(self.path)
	
	def __repr__(self):
		return 'Target(%r)' % (self.path,)
	
	def build(self, update):
		return self.state.perform_build(self.builder.path, lambda: self._perform_build(update))

	def _perform_build(self, update):
		'''
		Assumes locks are held (by state.perform_build)
		'''
		assert self.builder is not None
		assert os.path.exists(self.builder.path)
		if update:
			if not _is_dirty(self.state):
				log.debug("no build needed")
				return False
		exe_path = self.builder.path

		# dest may not exist, if a /gup/ directory is in use
		basedir = self.builder.basedir
		mkdirp(basedir)

		env = os.environ.copy()
		env['GUP_TARGET'] = os.path.abspath(self.path)
		jwack.extend_env(env)

		target_relative_to_cwd = os.path.relpath(self.path, var.ROOT_CWD)


		output_file = os.path.abspath(self.state.meta_path('out'))
		MOVED = False
		try:
			args = [os.path.abspath(exe_path), output_file, self.builder.target]
			log.info(target_relative_to_cwd)
			mtime = get_mtime(self.path)

			exe = guess_executable(exe_path)

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
				raise SafeError("%s is not executable and has no shebang line" % (exe_path,))

			new_mtime = get_mtime(self.path)
			if mtime != new_mtime:
				log.debug("old_mtime=%r, new_mtime=%r" % (mtime, new_mtime))
				if not os.path.isdir(self.path):
					# directories often need to be created directly
					log.warn("%s modified %s directly - this is rarely a good idea" % (exe_path, self.path))
			if ret == 0:
				if os.path.exists(output_file):
					if os.path.isdir(self.path):
						log.debug("calling rmtree() on previous %s", self.path)
						shutil.rmtree(self.path)
					os.rename(output_file, self.path)
				MOVED = True
			else:
				log.debug("builder exited with status %s" % (ret,))
				raise TargetFailed(target_relative_to_cwd, ret)
		finally:
			if not MOVED:
				try_remove(output_file)
		return True

	
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

