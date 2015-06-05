from __future__ import print_function
import os
from os import path
import errno
import subprocess
import logging

from .gupfile import Builder
from .error import *
from .util import *
from .state import TargetState
from .log import getLogger
from .var import ROOT_CWD, XTRACE, IS_WINDOWS
from .parallel import extend_build_env
_log = getLogger(__name__)

try:
	from pipes import quote
except ImportError:
	from shlex import quote

def prepare_build(p):
	builder = Builder.for_target(p)
	_log.trace('prepare_build(%r) -> %r' % (p, builder))
	if builder is not None:
		return Target(builder)
	return None

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
			_log.debug("DIRTY: %s (is buildable but has no stored deps)", state.path)
			return True

	if deps.already_built():
		_log.trace("CLEAN: %s has already been built in this invocation", state.path)
		return False

	dirty = deps.is_dirty(builder, built = False)
	_log.trace("deps.is_dirty(%r) -> %r", state.path, dirty)

	if dirty is True:
		return True

	if isinstance(dirty, list):
		for target in dirty:
			_log.trace("MAYBE_DIRTY: %s (unknown state - building it to find out)", target.path)
			target = prepare_build(target.path)
			if target is None:
				_log.trace("%s turned out not to be a target - skipping", target)
				continue
			target.build(update=True)

		dirty = deps.is_dirty(builder, built = True)
		assert dirty in (True, False)
		_log.trace("after rebuilding unknown targets, deps.is_dirty(%r) -> %r", state.path, dirty)

	if dirty is False:
		# not directly dirty - recurse children
		for path in deps.children():
			_log.trace("Recursing over dependency: %s", path)
			child = TargetState(path)
			if _is_dirty(child):
				_log.trace("_is_dirty(%r) -> True", child.path)
				return True
	return dirty

class Target(object):
	def __init__(self, builder):
		self.builder = builder
		self.path = self.builder.target_path
		self.state = TargetState(self.path)
	
	def __repr__(self):
		return 'Target(%r)' % (self.path,)
	
	def build(self, update):
		return self.state.perform_build(self.builder.path, lambda deps: self._perform_build(update, deps))

	def _perform_build(self, update, deps):
		'''
		Assumes locks are held (by state.perform_build)
		'''
		assert self.builder is not None
		assert os.path.exists(self.builder.path)
		if update:
			if not _is_dirty(self.state):
				_log.trace("no build needed")
				return False
		exe_path = os.path.abspath(self.builder.path)
		exe_path_relative_to_cwd = os.path.relpath(exe_path,ROOT_CWD)

		# dest may not exist, if a /gup/ directory is in use
		basedir = self.builder.basedir
		mkdirp(basedir)

		env = os.environ.copy()
		env['GUP_TARGET'] = os.path.abspath(self.path)
		extend_build_env(env)

		target_relative_to_cwd = os.path.relpath(self.path, ROOT_CWD)

		output_file = os.path.abspath(self.state.meta_path('out'))
		try_remove(output_file)

		MOVED = False
		try:
			args = [exe_path, output_file, self.builder.target]
			_log.info(target_relative_to_cwd)
			mtime = get_mtime(self.path)

			exe = _guess_executable(exe_path)

			if exe is not None:
				args = exe + args

			if XTRACE:
				_log.info(' # %s'% (os.path.abspath(basedir),))
				_log.info(' + ' + ' '.join(map(quote, args)))
			else:
				_log.trace(' from cwd: %s'% (os.path.abspath(basedir),))
				_log.trace('executing: ' + ' '.join(map(quote, args)))

			try:
				ret = self._run_process(args, cwd = basedir, env = env)
			except OSError:
				if exe: raise # we only expect errors when we could deduce no executable
				raise SafeError("%s is not executable and has no shebang line" % (exe_path_relative_to_cwd))

			new_mtime = get_mtime(self.path)
			target_changed = mtime != new_mtime
			if target_changed:
				_log.trace("old_mtime=%r, new_mtime=%r" % (mtime, new_mtime))
				if not lisdir(self.path):
					# directories often need to be created directly
					self.state.mark_clobbers()
					expect_clobber = False if deps is None else deps.clobbers
					if not (update and expect_clobber):
						_log.warn("%s modified %s directly" % (exe_path_relative_to_cwd, self.path))
			if ret == 0:
				if os.path.lexists(output_file):
					if os.path.lexists(self.path) and (
						lisdir(self.path) or lisdir(output_file)
					):
						_log.trace("removing previous %s", self.path)
						try_remove(self.path)
					rename(output_file, self.path)
				else:
					if (not target_changed) and (not os.path.islink(self.path)):
						_log.trace("removing old %s", self.path)
						try_remove(self.path)
				MOVED = True
			else:
				_log.trace("builder exited with status %s" % (ret,))
				raise TargetFailed(target_relative_to_cwd, ret)
		finally:
			if not MOVED:
				try_remove(output_file)
		return True

	
	def _run_process(self, args, cwd, env):
		try:
			proc = subprocess.Popen(args, cwd = cwd, env = env, close_fds=False)
		except OSError as e:
			if e.errno == errno.ENOENT:
				raise SafeError("Executable not found: %s" % (args[0],))
			raise e
		return proc.wait()

def _guess_executable(p):
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
	if IS_WINDOWS:
		bin = _resolve_windows_binary(bin)

	if os.path.isabs(bin) and not os.path.exists(bin):
		if os.path.basename(bin) == 'env':
			# special-cased for compatibility
			return args[1:]
		raise SafeError("No such interpreter: %s" % (os.path.abspath(bin),))

	args[0] = bin
	return args

def _resolve_windows_binary(name):
	exts = os.environ.get('PATHEXT', '').split(os.pathsep)
	def possible_file_extensions(path):
		for ext in exts:
			yield path + ext
		yield path

	def possible_paths():
		if os.path.isabs(name):
			for path in possible_file_extensions(name):
				yield path
		else:
			for prefix in os.environ['PATH'].split(os.pathsep):
				for path in possible_file_extensions(os.path.join(prefix, name)):
					yield path
	
	for path in possible_paths():
		if os.path.isfile(path) and os.access(path, os.X_OK):
			return path

	# If we found nothing, just return the original name.
	# It's probably not going to work, but Windows does
	# some nutty stuff with the registry.
	return name
