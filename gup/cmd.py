from __future__ import print_function
from . import builder
import sys
import logging
import optparse
import os

from . import builder
from .error import *
from .util import *
from .state import TargetState, AlwaysRebuild, Checksum, FileDependency, META_DIR
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
	p = None
	action = None

	try:
		cmd = argv[0]
	except IndexError:
		pass
	else:
		if cmd == '--clean':
			p = optparse.OptionParser('Usage: gup --clean [OPTIONS] [dir [...]]')
			action = clean_targets
			argv.pop(0)
		elif cmd == '--contents':
			p = optparse.OptionParser('Usage: gup --contents')
			action = mark_contents
			argv.pop(0)
		elif cmd == '--always':
			p = optparse.OptionParser('Usage: gup --always')
			action = mark_always
			argv.pop(0)
		elif cmd == '--ifcreate':
			p = optparse.OptionParser('Usage: gup --ifcreate [file [...]]')
			action = mark_ifcreate
			argv.pop(0)
	
	if action is None:
		# default parser
		p = optparse.OptionParser('Usage: gup [action] [OPTIONS] [target [...]]\n\n' +
			'Actions: (if present, the action must be the first argument)\n'
			'  --always     Mark this target as always-dirty\n' +
			'  --ifcreate   Rebuild the current target if the given file(s) are created\n' +
			'  --contents   Checksum the contents of stdin\n' +
			'  --clean      Clean any gup-built targets\n' +
			'  (use gup <action> --help) for further details')

		p.add_option('-u', '--update', '--ifchange', dest='update', action='store_true', help='Only rebuild stale targets', default=False)
		p.add_option('-j', '--jobs', type='int', default=1, help="Number of concurrent jobs to run")
		p.add_option('-x', '--trace', action='store_true', help='Trace build script invocations (also sets $GUP_XTRACE=1)')
		action = build

	p.add_option('-q', '--quiet', action='count', default=0, help='Decrease verbosity')
	p.add_option('-v', '--verbose', action='count', default=var.DEFAULT_VERBOSITY, help='Increase verbosity')
	opts, args = p.parse_args(argv)

	verbosity = opts.verbose - opts.quiet
	_init_logging(verbosity)

	log.debug('argv: %r, action=%r', argv, action)
	action(opts, args)

def _get_parent_target():
	t = os.environ.get('GUP_TARGET', None)
	if t is not None:
		assert os.path.isabs(t)
	return t

def _assert_parent_target(action):
	p = _get_parent_target()
	if p is None:
		raise SafeError("%s was used outside of a gup target" % (action,))
	return p

def mark_always(opts, targets):
	assert len(targets) == 0, "no arguments expected"
	parent_target = _assert_parent_target('--always')
	TargetState(parent_target).add_dependency(AlwaysRebuild())

def mark_ifcreate(opts, files):
	assert len(files) > 0, "at least one file expected"
	parent_target = _assert_parent_target('--ifcreate')
	parent_base = os.path.dirname(parent_target)
	parent_state = TargetState(parent_target)
	for file in files:
		if os.path.exists(file):
			raise SafeError("File already exists: %s" % (file,))
		parent_state.add_dependency(FileDependency.relative_to_target(parent_target, mtime=None, checksum=None, path = file))

def mark_contents(opts, targets):
	assert len(targets) == 0, "no arguments expected"
	assert not sys.stdin.isatty()
	parent_target = _assert_parent_target('--content')
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
	if opts.trace:
		var.set_trace()
	
	if len(targets) == 0:
		targets = ['all']
	assert len(targets) > 0

	parent_target = _get_parent_target()

	jobs = opts.jobs
	assert jobs > 0 and jobs < 1000
	jwack.setup(jobs)

	runner = TaskRunner()
	for target_path in targets:
		if os.path.abspath(target_path) == parent_target:
			raise SafeError("Target `%s` attempted to build itself" % (target_path,))

		task = Task(opts, parent_target, target_path)
		target = task.prepare()
		if target is not None:
			# only add a task if it's a buildable target
			runner.add(task)
		else:
			# otherwise, perform post-build actions (like updating parent dependencies)
			task.complete()

	# wait for all tasks to complete
	runner.run()

def main():
	try:
		_main(sys.argv[1:])
	except SafeError as e:
		if e.message is not None:
			log.error("%s" % (str(e),))
		sys.exit(1)

if __name__ == '__main__':
	main()
