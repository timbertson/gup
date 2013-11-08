from __future__ import print_function
import sys
import logging
import optparse
import os

from . import builder
from .error import *
from .util import *
from .state import FileDependency, TargetState
from .log import RED, GREEN, YELLOW, BOLD, PLAIN, getLogger
from . import var
log = getLogger(__name__)

def _init_logging(verbosity):
	lvl = logging.INFO
	fmt = '%(color)sgup  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN

	if verbosity < 0:
		lvl = logging.ERROR
	elif verbosity > 0:
		fmt = '%(color)sgup[%(name)s]  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN
		lvl = logging.DEBUG
	
	if var.RUNNING_TESTS:
		lvl = logging.DEBUG
		if var.IS_ROOT:
			logging.basicConfig(level=lvl)
			return

	# persist for child processes
	var.set_verbosity(verbosity)

	baseLogger = getLogger('gup')
	handler = logging.StreamHandler()
	handler.setFormatter(logging.Formatter(fmt))
	baseLogger.propagate = False
	baseLogger.setLevel(lvl)
	baseLogger.addHandler(handler)


def _main(args):
	p = optparse.OptionParser('Usage: gup [OPTIONS] [target [...]]')
	p.add_option('-u', '--update', '--ifchange', dest='update', action='store_true', help='Only rebuild stale targets', default=False)
	p.add_option('--ifcreate', action='store_true', help='Declare a dependency on a nonexistent file', default=False)
	p.add_option('--xxx', action='store_const', const=None, dest='action', default=build, help='TODO')
	p.add_option('-v', '--verbose', action='count', default=var.DEFAULT_VERBOSITY, help='verbose')
	p.add_option('-q', '--quiet', action='count', default=0, help='quiet')
	p.add_option('-x', '--trace', action='store_true', help='xtrace')
	opts, args = p.parse_args(args)

	verbosity = opts.verbose - opts.quiet
	_init_logging(verbosity)

	if opts.trace:
		var.set_trace()
	opts.action(opts, args)

def build(opts, targets):
	if len(targets) == 0:
		targets = ['all']
	assert len(targets) > 0

	def report_nobuild(target):
		if var.IS_ROOT:
			log.info("%s: up to date", target)
		else:
			log.debug("%s: up to date", target)

	parent_target = os.environ.get('GUP_TARGET', None)
	if parent_target is not None:
		assert os.path.isabs(parent_target)

	def build_target(target):
		if os.path.abspath(target) == parent_target:
			raise SafeError("Target `%s` attempted to build itself" % (target,))

		task = builder.prepare_build(target)
		log.debug('prepare_build(%r) -> %r' % (target, task))
		if task is None:
			if opts.ifcreate:
				if parent_target is None:
					log.warn("--ifcreate was used outside of a gup target")
				return
			if opts.update and os.path.exists(target):
				report_nobuild(target)
				return
			raise Unbuildable("Don't know how to build %s" % (target))

		if opts.update and not task.is_dirty():
			report_nobuild(target)
			return

		task.build(force = not opts.update)

	for target in targets:
		build_target(target)
		if parent_target is not None:
			mtime = get_mtime(target)
			relpath = os.path.relpath(os.path.abspath(target), os.path.dirname(parent_target))

			dep = FileDependency(mtime=mtime, path=relpath)
			TargetState(parent_target).add_dependency(dep)

def main():
	try:
		_main(sys.argv[1:])
	except SafeError as e:
		log.error("%s" % (str(e),))
		sys.exit(1)

if __name__ == '__main__':
	main()
