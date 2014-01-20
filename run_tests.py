#!/usr/bin/env python
import os, sys, subprocess

class Object(object): pass

UNIT = '-u'
INTEGRATION = '-i'
actions = (UNIT, INTEGRATION)

action = sys.argv[1]
assert action in actions, "Expected one of %s" % (", ".join(actions),)
action_name = 'unit' if action == UNIT else 'integration'
args = sys.argv[2:]

cwd = os.getcwd()
kind = os.path.basename(cwd)
kinds = ('python', 'ocaml')
if kind not in kinds:
	kind = None

root = os.path.abspath(os.path.dirname(__file__))
test_dir = os.path.join(root, 'test')

try:
	def run_nose(args):
		if os.environ.get('CI', 'false') == 'true':
			args = args + ['-v']
		subprocess.check_call(['make', '-C', root, 'gup-test-local.xml'])
		subprocess.check_call([
			'0install', 'run', '--command=' + os.environ.get('TEST_COMMAND', 'test'),
			os.path.join(root, 'gup-test-local.xml')] + args)

	subprocess.check_call(['make', '%s-test-pre' % action_name])

	def add_to_env(name, val):
		vals = os.environ.get(name, '').split(os.pathsep)
		vals.insert(0, val)
		os.environ[name] = os.pathsep.join(vals)

	if action == INTEGRATION:
		# run without adding to PATH
		if kind is None:
			exe = os.pathsep.join([os.path.join(cwd, kind, 'bin', 'gup') for kind in kinds])
		else:
			exe = os.path.join(cwd, 'bin', 'gup')
		os.environ['GUP_EXE'] = exe
		run_nose(['-w', test_dir] + args)
	else:
		assert action == UNIT
		add_to_env('PATH', os.path.join(root, 'test/bin'))
		if kind == 'ocaml':
			subprocess.check_call(['./test.byte', '-runner', 'sequential'] + args)
		else:
			add_to_env('PYTHONPATH', os.path.join(root, 'python'))
			run_nose(args)

except subprocess.CalledProcessError: sys.exit(1)
