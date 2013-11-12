from __future__ import print_function
from . import builder
import sys
import logging
import optparse
import os

from . import builder
from .error import *
from .util import *
from .state import TargetState, AlwaysRebuild, Checksum, META_DIR
from .log import PLAIN, getLogger
from . import var
from . import jwack
from .task import Task, TaskRunner

log = getLogger('gup.cmd') # hard-coded in case of __main__

def _init_logging(verbosity):
	lvl = logging.INFO
	fmt = '%(color)sgup  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN

	if verbosity < 0:
		lvl = logging.ERROR
	elif verbosity > 0:
		fmt = '%(color)sgup[%(process)s %(asctime)s %(name)-11s %(levelname)-5s]  ' + var.INDENT + '%(bold)s%(message)s' + PLAIN
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


def _main(argv):
	p = optparse.OptionParser('Usage: gup [OPTIONS] [target [...]]')
	p.add_option('-u', '--update', '--ifchange', dest='update', action='store_true', help='Only rebuild stale targets', default=False)

	# TODO: give --contents and --clean their own parsers
	p.add_option('--contents', action='store_const', help='Treat target as unchanged if the contents (of stdin) match the stored value', const=mark_contents, dest='action')
	p.add_option('--clean', action='store_const', help='Clean any gup-built targets', const=clean_targets, dest='action')

	p.add_option('--ifcreate', action='store_true', help='Redo this target if file is created', default=False)
	p.add_option('--always', action='store_const', dest='action', const=mark_always)
	p.add_option('-j', '--jobs', type='int', default=1, help="number of concurrent jobs to run")
	p.add_option('-v', '--verbose', action='count', default=var.DEFAULT_VERBOSITY, help='verbose')
	p.add_option('-q', '--quiet', action='count', default=0, help='quiet')
	p.add_option('-x', '--trace', action='store_true', help='xtrace')
	opts, args = p.parse_args(argv)

	verbosity = opts.verbose - opts.quiet
	_init_logging(verbosity)

	if opts.trace:
		var.set_trace()
	
	log.debug('argv: %r, action=%r', argv, opts.action)
	(opts.action or build)(opts, args)

def _get_parent_target():
	t = os.environ.get('GUP_TARGET', None)
	if t is not None:
		assert os.path.isabs(t)
	return t

def _assert_no_builder_opts(reason, opts):
	assert not opts.update, "You can't pass both --update and %s" % (reason,)
	assert not opts.ifcreate, "You can't pass both --ifcreate and %s" % (reason,)

def mark_always(opts, targets):
	_assert_no_builder_opts('--always', opts)
	assert len(targets) == 0, "no arguments expected"
	parent_target = _get_parent_target()
	if parent_target is None:
		log.warn("--always was used outside of a gup target")
		return
	TargetState(parent_target).add_dependency(AlwaysRebuild())

def mark_contents(opts, targets):
	_assert_no_builder_opts('--contents', opts)
	assert len(targets) == 0, "no arguments expected"
	assert not sys.stdin.isatty()
	parent_target = _get_parent_target()
	if parent_target is None:
		log.warn("--contents was used outside of a gup target")
		return
	TargetState(parent_target).add_dependency(Checksum.from_stream(sys.stdin))

def clean_targets(opts, dests):
	import shutil
	if len(dests) == 0: dests = ['.']
	for dest in dests:
		for dirpath, dirnames, filenames in os.walk(dest, followlinks=False):
			if META_DIR in dirnames:
				gupdir = os.path.join(dirpath, META_DIR)
				deps = TargetState.built_targets(gupdir)
				for dep in deps:
					if dep in filenames:
						target = os.path.join(dirpath, dep)
						log.warn("remove: %s" % (target,))
						try:
							os.remove(target)
						except OSError:
							shutil.rmtree(target)
				log.warn("remove: %s" % (gupdir,))
				shutil.rmtree(gupdir)
			# filter out hidden directories
			dirnames = [d for d in dirnames if not d.startswith('.')]

def build(opts, targets):
	if len(targets) == 0:
		targets = ['all']
	assert len(targets) > 0

	parent_target = _get_parent_target()

	jobs = opts.jobs
	assert jobs > 0 and jobs < 1000
	jwack.setup(jobs)

	runner = TaskRunner()
	for target_path in targets:
		task = Task(opts, parent_target, target_path)
		target = task.prepare()
		if target is not None:
			# only add a task if it's a buildable target
			runner.add(task.build)
		else:
			# otherwise, perform post-build actions (like updating parent dependencies)
			task.complete()

	# wait for all tasks to complete
	runner.run()

def main():
	try:
		_main(sys.argv[1:])
	except SafeError as e:
		log.error("%s" % (str(e),))
		sys.exit(1)

if __name__ == '__main__':
	main()
