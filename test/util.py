from __future__ import print_function
from mocktest import *
import mocktest
import os
import sys
import tempfile
import shutil
import contextlib
import subprocess
import logging

from gup import cmd, var
from gup.error import *

# (for log redirection)
var.RUNNING_TESTS = True

logging.basicConfig(level=logging.DEBUG)
log = logging.getLogger('TEST')

TEMP = os.path.join(os.path.dirname(__file__), 'tmp')

def mkdirp(p):
	if not os.path.exists(p):
		os.makedirs(p)

BASH = '#!/bin/bash\nset -eu\n'
def echo_to_target(contents):
	return BASH + 'echo -n "%s" > "$1"' % (contents,)

class TestCase(mocktest.TestCase):
	def setUp(self):
		super(TestCase, self).setUp()
		mkdirp(TEMP)
		self.ROOT = tempfile.mkdtemp(dir=TEMP)
		log.debug('root: %s', self.ROOT)
	
	def path(self, p):
		return os.path.join(self.ROOT, p)

	def write(self, p, contents):
		p = self.path(p)
		mkdirp(os.path.dirname(p))
		with open(p, 'w') as f:
			f.write(contents)

	def read(self, p):
		with open(self.path(p)) as f:
			return f.read()
	
	def tearDown(self):
		shutil.rmtree(self.ROOT)
		super(TestCase, self).tearDown()

	@contextlib.contextmanager
	def _root_cwd(self):
		initial = os.getcwd()
		try:
			os.chdir(self.ROOT)
			yield
		finally:
			os.chdir(initial)

	def _build(self, args, cwd=None):
		log.warn("Running build with args: %r" % (list(args)))
		with self._root_cwd():
			if cwd is not None:
				os.chdir(cwd)
			cmd._main(list(args))

	def build(self, *targets, **k):
		self._build(targets, **k)

	def mtime(self, p):
		mtime = os.stat(os.path.join(self.ROOT, p)).st_mtime
		logging.debug("mtime %s for %s" % (mtime,p))
		return mtime

	def build_u(self, *targets, **k):
		self._build(['--update'] + list(targets), **k)
	
	def build_assert(self, target, contents):
		self.build(target)
		self.assertEqual(self.read(target), contents)

	def build_u_assert(self, target, contents):
		self.build(target)
		self.assertEqual(self.read(target), contents)
	
	def touch(self, target):
		with open(self.path(target), 'a'): pass

	def assertRebuilt(self, target, fn):
		self.build_u(target)
		mtime = self.mtime(target)
		fn()
		self.build_u(target)
		self.assertNotEqual(self.mtime(target), mtime, "target %s didn't get rebuilt" % (target,))
	
	def assertNotRebuilt(self, target, fn):
		self.build_u(target)
		mtime = self.mtime(target)
		fn()
		self.build_u(target)
		self.assertEqual(self.mtime(target), mtime, "target %s got rebuilt" % (target,))



