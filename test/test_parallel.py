from .util import *
from datetime import datetime, timedelta

if not IS_WINDOWS:
	# we disable parallel builds on windows, so
	# these tests won't pass

	class TestParallelBuilds(TestCase):
		def setUp(self):
			super(TestParallelBuilds, self).setUp()
			self.write('build-step.gup', BASH + 'gup -u counter; echo ok > $1')
			self.write('Gupfile', 'build-step.gup:\n\tstep*')
			self.write('counter', '1')
			self.write('counter.gup', BASH + '''
				sleep 1
				expr "$(cat $2)" + 1 > $1
				gup --always
			''')

		def test_target_waits_for_existing_build_to_complete(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']
			initial_time = datetime.now()
			self.build_u('-j10', *steps, last=True)

			self.assertEquals(self.read('counter'), '2')
			elapsed_time = (datetime.now() - initial_time).total_seconds()
			log.warn("elapsed time: %r" % (elapsed_time,))
			# since build sleeps for 1 second, rebuilding it for each
			# dep would take 6+ seconds
			self.assertTrue(elapsed_time < 2)

		def test_nested_tasks_are_executed_in_parallel(self):
			steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']
			self.write('all-steps.gup', BASH + 'gup -u ' + ' '.join(steps))

			initial_time = datetime.now()
			self.build_u('-j10', *steps, last=True)

			self.assertEquals(self.read('counter'), '2')
			elapsed_time = (datetime.now() - initial_time).total_seconds()
			log.warn("elapsed time: %r" % (elapsed_time,))
			# since build sleeps for 1 second, rebuilding it for each
			# dep would take 6+ seconds
			self.assertTrue(elapsed_time < 2)
