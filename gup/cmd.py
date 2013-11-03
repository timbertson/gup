from __future__ import print_function
import sys
import logging
import optparse

from . import builder
from .error import *

logging.basicConfig(level=logging.DEBUG)

def main(args):
	p = optparse.OptionParser('Usage: gup [OPTIONS] [target [...]]')
	p.add_option('-u', '--update', action='store_true', help='Only rebuild stale targets', default=False)
	p.add_option('--xxx', action='store_const', const=None, dest='action', default=build, help='TODO')
	logging.debug("args: %r" % (args,))
	opts, args = p.parse_args(args)
	logging.debug("opts: %r" % (opts,))
	opts.action(opts, args)

def build(opts, targets):
	if len(targets) == 0: raise SafeError("You must provide at least one target to build")
	assert len(targets) > 0
	for target in targets:
		task = builder.prepare_build(target)
		logging.debug('prepare_build(%r) -> %r' % (target, task))
		if task is None:
			if opts.update:
				logging.debug("--update on source file: noop")
				return
			raise Unbuildable("Don't know how to build %s" % (target))
		task.build(force = not opts.update)

if __name__ == '__main__':
	main(sys.argv[1:])
