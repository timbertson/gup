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

from gup import cmd
from gup.error import *

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
		if not os.path.exists(TEMP):
			os.mkdir(TEMP)
		self.ROOT = tempfile.mkdtemp(dir=TEMP)
	
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

	def build(self, *targets):
		with self._root_cwd():
			cmd._main(list(targets))

	def mtime(self, p):
		return os.stat(os.path.join(self.ROOT, p)).st_mtime

	def build_u(self, *targets):
		with self._root_cwd():
			cmd._main(['--update'] + list(targets))
	
	def build_assert(self, target, contents):
		self.build(target)
		self.assertEqual(self.read(target), contents)

	def build_u_assert(self, target, contents):
		self.build(target)
		self.assertEqual(self.read(target), contents)

