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
from .log import RED, GREEN, YELLOW, BOLD, PLAIN, getLogger
from . import var
log = getLogger(__name__)

def _main(args):
	p = optparse.OptionParser('Usage: gup [OPTIONS] [target [...]]')
	p.add_option('-u', '--update', action='store_true', help='Only rebuild stale targets', default=False)
	p.add_option('--xxx', action='store_const', const=None, dest='action', default=build, help='TODO')
	p.add_option('-v', '--verbose', action='count', default=0, help='verbose')
	p.add_option('-q', '--quiet', action='count', default=0, help='quiet')
	p.add_option('-x', '--trace', action='store_true', help='xtrace')
	logging.debug("args: %r" % (args,))
	opts, args = p.parse_args(args)

	lvl = logging.INFO
	fmt = '%(color)sgup  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN

	verbosity = opts.verbose - opts.quiet
	if verbosity < 0:
		lvl = logging.ERROR
	elif verbosity > 0:
		fmt = '%(color)sgup[%(name)s]  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN
		lvl = logging.DEBUG
	
	if os.environ.get('GUP_IN_TESTS', '0') == '1':
		# XXX: forward logs to a specific file descriptor?
		lvl = logging.WARN

	baseLogger = getLogger('gup')
	handler = logging.StreamHandler()
	handler.setFormatter(logging.Formatter(fmt))
	baseLogger.propagate = False
	baseLogger.setLevel(lvl)
	baseLogger.addHandler(handler)

	if opts.trace:
		var.set_trace()
	log.debug('opts: %r' % (opts,))
	opts.action(opts, args)

def build(opts, targets):
	if len(targets) == 0: raise SafeError("You must provide at least one target to build")
	assert len(targets) > 0

	def report_nobuild(target):
		if var.IS_ROOT:
			log.info("%s: up to date", target)
		else:
			log.debug("%s: up to date", target)

	def build_target(target):
		task = builder.prepare_build(target)
		logging.debug('prepare_build(%r) -> %r' % (target, task))
		if task is None:
			if opts.update and os.path.exists(target):
				report_nobuild(target)
				return
			raise Unbuildable("Don't know how to build %s" % (target))

		if opts.update and not task.is_dirty():
			report_nobuild(target)
			return

		task.build(force = not opts.update)

	parent_target = os.environ.get('GUP_TARGET', None)
	if parent_target is not None:
		assert os.path.isabs(parent_target)

	for target in targets:
		build_target(target)
		if parent_target is not None:
			mtime = get_mtime(target)
			relpath = os.path.relpath(os.path.abspath(target), os.path.dirname(parent_target))

			dep = FileDependency(mtime=mtime, path=relpath)
			Target(parent_target).state.add_dependency(dep)

def main():
	try:
		_main(sys.argv[1:])
	except SafeError as e:
		log.error("%s" % (str(e),))
		sys.exit(1)

if __name__ == '__main__':
	main()
