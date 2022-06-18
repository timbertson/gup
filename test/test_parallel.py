from __future__ import print_function

if __name__ == '__main__':
	from util import *
else:
	from .util import *

import re

GUP_JOBSERVER = 'GUP_JOBSERVER'
MAKEFLAGS = 'MAKEFLAGS'
GUP_RPC = 'GUP_RPC'

def load_env(path):
	env = {}
	with open(path) as f:
		for line in f.read().splitlines():
			if '=' not in line: continue
			key, val = line.split('=',1)
			if key in (GUP_JOBSERVER, MAKEFLAGS, GUP_RPC):
				logging.debug("serialized env: %s=%s" % (key,val))
			env[key] = val
	return env


if not IS_WINDOWS:
	# we disable parallel builds on windows, so
	# these tests won't pass

	sleep_time = 2
	# travis-ci often executes under load, so multiply sleep_times to give more reliability
	if os.environ.get('CI', None): sleep_time *= 2

	class TestJobserverMode(TestCase):
		def setUp(self):
			super(TestJobserverMode, self).setUp()
			self.write('build-step.gup', BASH + 'env > "$2.env"; echo ok > $1')
			self.write('Gupfile', 'build-step.gup:\n\tstep*')

		def test_uses_named_pipe_or_rpc_jobserver(self):
			self.build('step1', '-j3')
			env = load_env(self.path('step1.env'))
			if IS_OCAML:
				assert env.get(GUP_RPC) is not None
			else:
				assert env.get(GUP_JOBSERVER) not in (None, '0'), env.get(GUP_JOBSERVER)
			assert env.get(MAKEFLAGS) is None

		@skipPermutations
		def test_doesnt_use_jobserver_for_serial_build(self):
			self.build('step1', '-j1')
			self.build('step2')

			for target in 'step1', 'step2':
				env = load_env(self.path(target + '.env'))
				if IS_OCAML:
					assert env.get(GUP_RPC) is None
				else:
					assert env.get(GUP_JOBSERVER) == '0'
				assert env.get(MAKEFLAGS) is None
				assert env.get(MAKEFLAGS) is None

	class TestParallelBuilds(TestCase):
		def setUp(self):
			super(TestParallelBuilds, self).setUp()
			self.write('build-step.gup', BASH + 'gup -u counter; sleep ' + str(sleep_time) + '; env > "$2.env"; echo ok > $1')
			self.write('Gupfile', 'build-step.gup:\n\tstep*')
			self.write('counter', '1')
			self.write('counter.gup', BASH + '''
				if [ -f counter.pid ]; then
					echo "counter job already running!" >&2
					exit 1
				fi
				echo $$ > counter.pid
				sleep %s
				expr "$(cat $2)" + 1 > $1
				gup --always
				rm counter.pid
			''' % sleep_time)
			self.write('long.gup', BASH + 'sleep ' + str(sleep_time*2))
			self.write('fail.gup', '#!false')

		def test_executes_tasks_in_parallel(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']

			def build():
				self.build_u('-j6', *steps, last=True)
				self.assertEquals(self.read('counter'), '2')

			# counter takes 1s, each step takes 1s
			self.assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

		def test_waits_for_all_jobs_to_complete_on_failure(self):
			def build():
				try:
					self.build('-j3', 'long', 'fail', 'step1')
				except SafeError as e:
					# we expect the build to fail, but it should
					# have completed `step1`
					self.assertEquals(self.read('step1'), 'ok')

			self.assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

		def test_releases_all_tokens_if_multiple_jobs_fail_in_a_single_proces(self):
			self.write('short_fail.gup', BASH + 'sleep ' + str(sleep_time) + '; exit 1')
			self.write('long_fail.gup', BASH + 'sleep ' + str(2*sleep_time) + '; exit 1')
			self.write('parent.gup', BASH + 'gup -u short_fail long_fail')
			# self.assertRaises(SafeError, lambda: self.build('-j9', 'parent'))
			self.assertRaises(SafeError, lambda: self.build('-j9', 'short_fail', 'long_fail'))

		def test_limiting_number_of_concurrent_jobs(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']

			# counter takes 1s, plus 3 pairs of 1s jobs (two at a time)
			self.assertDuration(min=4*sleep_time, max=5*sleep_time, fn=lambda: self.build_u('-j2', *steps, last=True))

			self.assertEquals(self.read('counter'), '2')

		def test_contention_on_built_target(self):
			# regression: releasing a flock() on a file releases
			# _all_ locks, so this fails if we don't handle reentrant
			# locking of deps files ourselves
			self.build('-u', 'counter')
			self.build('-j10', 'step1', 'step2')

		@skipPermutations
		@unittest.skipIf(IS_OCAML, "OCaml jobserver incompatible with Make")
		def test_uses_make_jobserver_when_present(self):
			gup = GUP_EXES[0] # + ' -vv'
			self.write("Makefile", "a:\n\t+" + gup + " step1 step2 step3\nb:\n\t+" + gup + " step4 step5 step6")

			def build():
				proc = subprocess.Popen(['make', '-j6', 'a', 'b'], cwd=self.ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
				out, _ = proc.communicate()
				for line in out.decode('ascii').splitlines():
					logging.debug(line)
				self.assertEqual(proc.returncode, 0, out)

				self.assertEquals(self.read('counter'), '2')

			self.assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

			env = load_env(self.path('step1.env'))
			self.assertEqual(env.get(GUP_JOBSERVER), None)
			self.assertTrue('--jobserver-' in env[MAKEFLAGS], env[MAKEFLAGS])

		def test_nested_tasks_are_executed_in_parallel(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']
			self.write('all-steps.gup', BASH + 'gup -u ' + ' '.join(steps))

			def build():
				self.build_u('-j6', *steps, last=True)
				self.assertEquals(self.read('counter'), '2')

			self.assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

		def test_multiple_attempts_in_one_process_to_build_the_same_target(self):
			os.symlink('./', self.path('link'))
			self.write('target.gup', BASH + 'echo 1 >> "$2"')
			self.build('--jobs=10', 'target', 'link/target')
			self.assertEquals(self.read('target'), '1')

		def test_multiple_targets_with_common_dependency(self):
			self.write('input.txt', '1')
			self.write('a.gup', BASH + 'gup -u input.txt ; cat input.txt > "$1" ; echo -n a >> "$1"')

			# both depend on a
			self.write('b.gup', BASH + 'gup -u a ; cat a > "$1" ; echo -n b >> "$1"')
			self.write('c.gup', BASH + 'gup -u a ; cat a > "$1" ; echo -n c >> "$1"')

			# depends on c
			self.write('d.gup', BASH + 'gup -u c ; cat c > "$1" ; echo -n d >> "$1"')

			self.build('--jobs=2', '-u', 'b', 'd')
			self.assertEquals(self.read('b'), '1ab')
			self.assertEquals(self.read('c'), '1ac')
			self.assertEquals(self.read('d'), '1acd')

			# BUG: both depend on a.
			# b causes a to rebuild (it's dirty), then is rebuilt naturally
			# When c is tested, its dependency (a) is already built and so
			# (in an earlier version) it's seen as clean
			self.write('input.txt', '2')
			self.build('--jobs=2', '-u', 'b', 'd')
			self.assertEquals(self.read('b'), '2ab')
			self.assertEquals(self.read('c'), '2ac') # ends up with 1ac when c isn't rebuilt
			self.assertEquals(self.read('d'), '2acd')

		def test_multiple_targets_with_common_dependency_checksum(self):
			# fake checksum to prevent rebuilding
			self.write('input', '1')
			self.write('input-checksum.gup', BASH + 'gup -u input; cat input > "$1"; echo UNCHANGED | gup --contents')

			self.write('a.gup', echo_file_contents('input-checksum') + '; echo -n a >> "$1"')
			self.write('b.gup', echo_file_contents('input-checksum') + '; echo -n b >> "$1"')
			self.write('c.gup', echo_file_contents('b') + '; echo -n c >> "$1"')

			self.build('--jobs=2', '-u', 'a', 'c')

			self.write('input', '2')
			self.build('--jobs=2', '-u', 'a', 'c')
			self.assertEquals(self.read('input-checksum'), '2')
			self.assertEquals(self.read('a'), '1a')
			self.assertEquals(self.read('b'), '1b')
			self.assertEquals(self.read('c'), '1bc')

	class TestLocking(TestCase):
		def test_deps_file_is_write_locked_during_build(self):
			self.write('target.gup', re.sub(r'^\t{4}', '', '''
				#!python
				from __future__ import print_function
				import os,sys,fcntl,errno
				dest = sys.argv[1]
				print(dest)
				dest_dir = os.path.dirname(dest)
				dest_fname = os.path.basename(dest).split('.', 1)[1]
				def dest_of(type):
					return os.path.join(dest_dir, type + '.' + dest_fname)
				deps_file = dest_of('deps')
				deps_lock = dest_of('deps-lock')
				newdeps_file = dest_of('deps2')
				newdeps_file_lock = dest_of('lock-deps2')

				print(repr(os.listdir(os.path.dirname(dest))))
				for lockfile in [deps_lock]:
					assert os.path.exists(lockfile), "%s does not exist" % lockfile
					with open(lockfile) as f:
						fcntl.flock
						try:
							fcntl.lockf(f, fcntl.LOCK_SH|fcntl.LOCK_NB, 0, 0)
						except IOError as e:
							if e.errno in (errno.EACCES, errno.EAGAIN):
								# good, we failed to get the lock
								pass
							else:
								raise e
						else:
							raise AssertionError("no exception thrown when locking %s" % lockfile)
	''', flags=re.M).strip())
			self.build('target')



if __name__ == '__main__':
	test = TestParallelBuilds()
	test.setUp()
	import pdb;pdb.set_trace()
