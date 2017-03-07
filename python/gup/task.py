from __future__ import print_function
import os
import errno
from .builder import prepare_build
from .log import getLogger
from .util import get_mtime
from .state import FileDependency, TargetState
from .error import Unbuildable, TargetFailed, SafeError
from .path import traverse_from
from .var import IS_ROOT

_log = getLogger(__name__)

class Task(object):
	'''
	Each target we're asked to build is represented as a Task,
	so that they can be invoked in parallel
	'''
	def __init__(self, opts, parent_target, target_path):
		self.target_path = target_path
		self.opts = opts
		self.parent_target = parent_target
	
	def prepare(self):
		'''
		Returns:
			- None (not buildable),
			- Task (depends implicitly on another task; i.e. a symlink)
			- Target (buildable)
		'''

		target_path = self.target_path
		opts = self.opts

		target = self.target = prepare_build(target_path)
		if target is None:
			target_dest = None
			try:
				target_dest = os.readlink(target_path)
			except (OSError) as e:
				if e.errno in (errno.ENOENT, errno.EINVAL):
					# not a link
					pass
				else:
					raise

			if target_dest is not None:
				# this target isn't buildable, but its symlink destination might be
				if not os.path.isabs(target_dest):
					target_dest = os.path.join(os.path.dirname(target_path), target_dest)
				dest = Task(self.opts, self.parent_target, target_dest)
				return dest

			if opts.update and os.path.lexists(target_path):
				self.report_nobuild()
			else:
				raise Unbuildable(target_path)
		return target

	def build(self):
		'''
		run in a child process
		'''
		self.built = self.target.build(update=self.opts.update)
		self.complete()

	def complete(self):
		if self.parent_target is not None:
			intermediate_paths, target_path = traverse_from(os.getcwd(), self.target_path)
			mtime = get_mtime(target_path)

			if self.target:
				dep = FileDependency.of_target(self.parent_target, self.target, mtime=mtime)
			else:
				dep = FileDependency.relative_to_target(self.parent_target, mtime=mtime, path=self.target_path)

			state = TargetState(self.parent_target)
			state.add_dependency(dep)
			if intermediate_paths or True:
				_log.trace("adding intermediate paths: %r", intermediate_paths)
				for intermediate in intermediate_paths:
					dep = FileDependency.relative_to_target(
							self.parent_target,
							path=intermediate,
							mtime=get_mtime(intermediate))
					state.add_dependency(dep)
	
	def handle_result(self, rv):
		_log.trace("build process exited with status: %r" % (rv,))
		if rv == 0:
			return
		if rv == SafeError.exitcode:
			# already logged - just raise an empty exception to propagate exit code
			raise SafeError(None)
		else:
			raise RuntimeError("unknown error in child process - exit status %s" % rv)

	def report_nobuild(self):
		if IS_ROOT:
			_log.info("%s: up to date", self.target_path)
		else:
			_log.trace("%s: up to date", self.target_path)


class TaskRunner(object):
	def __init__(self):
		self.tasks = []

	def add(self, fn):
		self.tasks.append(fn)

	def run(self):
		from .parallel import start_job, wait_all
		while self.tasks:
			task = self.tasks.pop(0)
			start_job(task.build, task.handle_result)
		wait_all()
	
