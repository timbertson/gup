from __future__ import print_function
import sys
import logging
import optparse
import os

from . import builder
from .error import *
from .util import *
from .state import FileDependency
from .builder import Target

logging.basicConfig(level=logging.DEBUG)

def _main(args):
	p = optparse.OptionParser('Usage: gup [OPTIONS] [target [...]]')
	p.add_option('-u', '--update', action='store_true', help='Only rebuild stale targets', default=False)
	p.add_option('--xxx', action='store_const', const=None, dest='action', default=build, help='TODO')
	logging.debug("args: %r" % (args,))
	opts, args = p.parse_args(args)
	logging.debug("opts: %r" % (opts,))

	if 'GUP_ROOT_CWD' not in os.environ:
		os.environ['GUP_ROOT_CWD'] = os.getcwd()

	opts.action(opts, args)

def build(opts, targets):
	if len(targets) == 0: raise SafeError("You must provide at least one target to build")
	assert len(targets) > 0

	def build_target(target):
		task = builder.prepare_build(target)
		logging.debug('prepare_build(%r) -> %r' % (target, task))
		if task is None:
			if opts.update and os.path.exists(target):
				logging.debug("--update on source file: noop")
				return
			raise Unbuildable("Don't know how to build %s" % (target))

		if opts.update and not task.is_dirty():
			logging.debug('up to date: %s' % (target,))
			return

		task.build(force = not opts.update)

	parent_target = os.environ.get('GUP_TARGET', None)
	if parent_target is not None:
		assert os.path.isabs(parent_target)

	for target in targets:
		build_target(target)
		if parent_target is not None:
			mtime = get_mtime(target)
			logging.warn("PARENT_TARGET=%r, TARGET=%r" % (parent_target, target))
			relpath = os.path.relpath(os.path.abspath(target), os.path.dirname(parent_target))

			dep = FileDependency(mtime=mtime, path=relpath)
			Target(parent_target).state.add_dependency(dep)

def main():
	try:
		_main(sys.argv[1:])
	except SafeError as e:
		print("Error: %s" % (str(e),), file=sys.stderr)
		sys.exit(1)

if __name__ == '__main__':
	main()
