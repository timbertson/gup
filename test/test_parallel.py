from __future__ import print_function

if __name__ == '__main__':
	from util import *
else:
	from .util import *
from datetime import datetime, timedelta

GUP_JOBSERVER = 'GUP_JOBSERVER'
MAKEFLAGS = 'MAKEFLAGS'

def assertDuration(min, max, fn):
	initial_time = datetime.now()
	rv = fn()

	elapsed_time = (datetime.now() - initial_time).total_seconds()
	assert elapsed_time <= max, "elapsed time > %ss (%s)" % (max, elapsed_time)
	assert elapsed_time >= min, "elapsed time < %ss (%s)" % (min, elapsed_time)
	return rv

def load_env(path):
	env = {}
	with open(path) as f:
		for line in f.read().splitlines():
			if '=' not in line: continue
			key, val = line.split('=',1)
			if key in (GUP_JOBSERVER, MAKEFLAGS):
				logging.debug("serialized env: %s=%s" % (key,val))
			env[key] = val
	return env


if not IS_WINDOWS:
	# we disable parallel builds on windows, so
	# these tests won't pass

	sleep_time = 1
	# travis-ci often executes under load, so multiply sleep_times to give more reliability
	if os.environ.get('CI', None): sleep_time = 2

	class TestJobserverMode(TestCase):
		def setUp(self):
			super(TestJobserverMode, self).setUp()
			self.write('build-step.gup', BASH + 'env > "$2.env"; echo ok > $1')
			self.write('Gupfile', 'build-step.gup:\n\tstep*')

		def test_uses_named_pipe_for_jobserver(self):
			self.build('step1', '-j3')
			env = load_env(self.path('step1.env'))
			assert env.get(GUP_JOBSERVER) not in (None, '0'), env.get(GUP_JOBSERVER)
			assert env.get(MAKEFLAGS) is None

		def test_doesnt_use_jobserver_for_serial_build(self):
			self.build('step1', '-j1')
			self.build('step2')

			for target in 'step1', 'step2':
				env = load_env(self.path(target + '.env'))
				assert env.get(GUP_JOBSERVER) == '0'
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

		def test_executes_tasks_in_parallel(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']

			def build():
				self.build_u('-j6', *steps, last=True)
				self.assertEquals(self.read('counter'), '2')

			# counter takes 1s, each step takes 1s
			assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

		def test_limiting_number_of_concurrent_jobs(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']

			# counter takes 1s, plus 3 pairs of 1s jobs (two at a time)
			assertDuration(min=4*sleep_time, max=5*sleep_time, fn=lambda: self.build_u('-j2', *steps, last=True))

			self.assertEquals(self.read('counter'), '2')

		def test_contention_on_built_target(self):
			# regression: releasing a flock() on a file releases
			# _all_ locks, so this fails if we don't handle reentrant
			# locking of .deps files ourselves
			self.build('-u', 'counter')
			self.build('-j10', 'step1', 'step2')

		@skipPermutations
		def test_uses_make_jobserver_when_present(self):
			gup = GUP_EXES[0] # + ' -vv'
			self.write("Makefile", "a:\n\t+" + gup + " step1 step2 step3\nb:\n\t+" + gup + " step4 step5 step6")

			def build():
				proc = subprocess.Popen(['make', '-j6', 'a', 'b'], cwd=self.ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
				out, _ = proc.communicate()
				self.assertEqual(proc.returncode, 0, out)

				self.assertEquals(self.read('counter'), '2')

			assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

			env = load_env(self.path('step1.env'))
			self.assertEqual(env.get(GUP_JOBSERVER), None)
			self.assertTrue('--jobserver-fds=' in env[MAKEFLAGS], env[MAKEFLAGS])

		def test_nested_tasks_are_executed_in_parallel(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']
			self.write('all-steps.gup', BASH + 'gup -u ' + ' '.join(steps))

			def build():
				self.build_u('-j6', *steps, last=True)
				self.assertEquals(self.read('counter'), '2')

			assertDuration(min=2*sleep_time, max=3*sleep_time, fn=build)

if __name__ == '__main__':
	test = TestParallelBuilds()
	test.setUp()
	import pdb;pdb.set_trace()
