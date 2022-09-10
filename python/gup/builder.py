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
from .var import ROOT_CWD, XTRACE, IS_WINDOWS, keep_failed_outputs
from .path import resolve_base
from .parallel import extend_build_env
_log = getLogger(__name__)

try:
	from pipes import quote
except ImportError:
	from shlex import quote

def prepare_build(p):
	p = resolve_base(p)
	builder = Builder.for_target(p)
	_log.trace('prepare_build(%r) -> %r' % (p, builder))
	if builder is not None:
		return Target(builder)
	return None

def _build_if_dirty(target, allow_build):
	'''
	Returns whether the dependency was built (or would be).
	Also builds any targets required to check dirtiness.
	'''

	def perform_build(target):
		if allow_build:
			target.perform_build(from_update=True)
		return True

	def build_target_if_dirty(target):
		if target.builder.parent is not None:
			if build_target_if_dirty(Target(target.builder.parent)):
				_log.debug("DIRTY: builder was rebuilt")
				return perform_build(target)

		deps = target.state.deps()
		if deps is None:
			_log.debug("DIRTY: %s (is buildable but has no stored deps)", target.path)
			return perform_build(target)

		if deps.already_built():
			_log.trace("DIRTY: %s was previously built in this invocation", target.path)
			return True

		built_children = set()
		def build_child_if_dirty(path):
			if path in built_children:
				return False
			else:
				built_children.add(path)
				_log.trace("Recursing over dependency: %s -> %s", target.path, path)
				child = prepare_build(path)
				if child is not None:
					child_dirty = build_target_if_dirty(child)
					_log.trace("_is_dirty(%s) -> %s", child, child_dirty)
					return child_dirty
				return False

		if not allow_build:
			child_dirty = []
			def wrapped_build(path):
				built = build_child_if_dirty(path)
				if built:
					child_dirty.append(True)
				return False
			dirty = deps.is_dirty(target.builder, wrapped_build)
			dirty = dirty or bool(child_dirty)
		else:
			dirty = deps.is_dirty(target.builder, build_child_if_dirty)
		_log.trace("deps.is_dirty(%r) -> %r", target.path, dirty)
		if dirty:
			return perform_build(target)
		return False

	return build_target_if_dirty(target)

class Target(object):
	def __init__(self, builder):
		self.builder = builder
		self.path = self.builder.target_path
		self.state = TargetState(self.path)
	
	def __repr__(self):
		return 'Target(%r)' % (self.path,)
	
	def build_or_update(self, update):
		if update:
			built = _build_if_dirty(self, True)
			if not built:
				_log.trace("no build needed")
		else:
			self.perform_build(False)
			built = True

		return built

	def is_dirty(self):
		return _build_if_dirty(self, allow_build = False)

	def perform_build(self, from_update):
		self.state.perform_build(self.builder, lambda deps: self._perform_build(deps, from_update))

	def _perform_build(self, deps, from_update):
		'''
		Assumes locks are held (by state.perform_build)
		'''
		assert self.builder is not None
		assert os.path.exists(self.builder.path)
		exe_path = path.abspath(self.builder.path)
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

		cleanup_output_file = True
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
					if not (from_update and expect_clobber):
						_log.warning("%s modified %s directly" % (exe_path_relative_to_cwd, self.path))
			if ret == 0:
				if os.path.lexists(output_file):
					if os.path.lexists(self.path) and (
						lisdir(self.path) or lisdir(output_file)
					):
						_log.trace("removing previous %s", self.path)
						try_remove(self.path)
					rename(output_file, self.path)
				else:
					if (not target_changed) and (os.path.lexists(self.path)) and (not os.path.islink(self.path)):
						_log.warning("Removing stale target: %s", target_relative_to_cwd)
						try_remove(self.path)
				cleanup_output_file = False # not needed
			else:
				temp_file = None
				if keep_failed_outputs():
					cleanup_output_file = False # not wanted
					if os.path.lexists(output_file):
						temp_file = os.path.relpath(output_file, ROOT_CWD)
				_log.trace("builder exited with status %s" % (ret,))
				raise TargetFailed(target_relative_to_cwd, ret, temp_file)
		finally:
			if cleanup_output_file:
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
	with open(p, 'rb') as f:
		line = f.readline(255)
	if not line.startswith(b'#!'):
		return None
	args = line[2:].decode('ascii').strip().split()
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
