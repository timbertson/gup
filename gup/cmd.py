from __future__ import print_function
import sys
import logging
import optparse
import os

from . import builder
from .error import *
from .util import *
from .state import FileDependency, TargetState, AlwaysRebuild
from .log import RED, GREEN, YELLOW, BOLD, PLAIN, getLogger
from . import var

log = getLogger('gup.cmd') # hard-coded in case of __main__

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
	p.add_option('--ifcreate', action='store_true', help='Redo this target if file is created', default=False)
	p.add_option('--always', action='store_const', dest='action', const=mark_always)
	p.add_option('-v', '--verbose', action='count', default=var.DEFAULT_VERBOSITY, help='verbose')
	p.add_option('-q', '--quiet', action='count', default=0, help='quiet')
	p.add_option('-x', '--trace', action='store_true', help='xtrace')
	opts, args = p.parse_args(args)

	verbosity = opts.verbose - opts.quiet
	_init_logging(verbosity)

	if opts.trace:
		var.set_trace()
	(opts.action or build)(opts, args)

def _get_parent_target():
	t = os.environ.get('GUP_TARGET', None)
	if t is not None:
		assert os.path.isabs(t)
	return t

def mark_always(opts, targets):
	assert len(targets) == 0, "no arguments expected"
	parent_target = _get_parent_target()
	if parent_target is None:
		log.warn("--always was used outside of a gup target")
		return
	TargetState(parent_target).add_dependency(AlwaysRebuild())

def build(opts, targets):
	if len(targets) == 0:
		targets = ['all']
	assert len(targets) > 0

	def report_nobuild(target):
		if var.IS_ROOT:
			log.info("%s: up to date", target)
		else:
			log.debug("%s: up to date", target)

	parent_target = _get_parent_target()

	def build_target(target_path):
		if os.path.abspath(target_path) == parent_target:
			raise SafeError("Target `%s` attempted to build itself" % (target_path,))

		target = builder.prepare_build(target_path)
		log.debug('prepare_build(%r) -> %r' % (target_path, target))
		if target is None:
			if opts.ifcreate:
				if parent_target is None:
					log.warn("--ifcreate was used outside of a gup target")
				return
			if opts.update and os.path.exists(target_path):
				report_nobuild(target_path)
				return
			raise Unbuildable("Don't know how to build %s" % (target_path))

		if opts.update and not target.is_dirty():
			report_nobuild(target_path)
			return

		target.build(force = not opts.update)

	for target_path in targets:
		build_target(target_path)
		if parent_target is not None:
			mtime = get_mtime(target_path)
			relpath = os.path.relpath(os.path.abspath(target_path), os.path.dirname(parent_target))

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
