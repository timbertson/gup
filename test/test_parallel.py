from .util import *

class TestParallelBuilds(TestCase):
	def test_target_waits_for_existing_build_to_complete(self):
		self.write('build-step.gup', BASH + 'gup -u counter; echo ok > $1')
		self.write('Gupfile', 'build-step.gup:\n\tstep*')
		self.write('counter', '1')
		self.write('counter.gup', BASH + '''
			sleep 1
			expr "$(cat $2)" + 1 > $1
			gup --always
		''')

		steps = ['step1', 'step2', 'step3', 'step4', 'step5', 'step6']
		from datetime import datetime, timedelta
		initial_time = datetime.now()
		self.build_u('-j10', *steps)

		self.assertEquals(self.read('counter'), '2')
		elapsed_time = (datetime.now() - initial_time).total_seconds()
		log.warn("elapsed time: %r" % (elapsed_time,))
		# since build sleeps for 0.5 seconds, rebuilsing it for each
		# dep would take 3+ seconds
		self.assertTrue(elapsed_time < 2)
