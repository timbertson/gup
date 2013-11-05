from util import *

class TestDirectDependencies(TestCase):
	def setUp(self):
		super(TestDirectDependencies, self).setUp()
		self.write("dep.gup", BASH + 'gup -u counter; echo -n "COUNT: $(cat counter)" > "$1"')

	def test_doesnt_rebuild_unnecessarily(self):
		self.assertRaises(TargetFailed, lambda: self.build("dep"))

		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		mtime = self.mtime('dep')

		self.build_u("dep")
		self.assertEqual(self.mtime('dep'), mtime)
	
	def test_rebuilds_on_dependency_change(self):
		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		self.write("counter", "2")
		self.build_u_assert("dep", "COUNT: 2")
	
	def test_rebuilds_on_transitive_dependency_change(self):
		self.write("counter.gup", BASH + 'gup -u counter2; echo -n "$(expr "$(cat counter2)" + 1)" > $1')

		self.write("counter2", "1")
		self.build_u('dep')
		self.assertEqual(self.read('dep'), 'COUNT: 2')
		self.assertEqual(self.read("counter"), "2")

		dep_m = self.mtime('dep')
		counter_m = self.mtime('counter')

		self.build_u('dep')
		self.assertEqual(self.mtime('dep'), dep_m)
		self.assertEqual(self.mtime('counter'), counter_m)

		self.write("counter2", "2")
		self.build_u("dep")
		self.assertEqual(self.read("dep"), "COUNT: 3")
		self.assertEqual(self.read("counter"), "3")


