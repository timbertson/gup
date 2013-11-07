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
	
class TestNonexistentDeps(TestCase):
	def test_rebuilt_on_creation_of_dependency(self):
		self.write('all.gup', BASH + 'gup --ifcreate foo; echo 1 > $1')

		self.assertNotRebuilt('all', lambda: self.touch('bar'))
		self.assertRebuilt('all', lambda: self.touch('foo'))
		self.assertNotRebuilt('all', lambda: None)


class TestPsuedoTasks(TestCase):
	def test_treats_targets_without_output_as_always_dirty(self):
		self.write('target.gup', BASH + 'echo "BUILDING" >&2; echo "updated" > somefile')

		self.build_u('target')
		self.assertFalse(os.path.exists(self.path('target')))
		mtime = self.mtime('somefile')

		# no output created - should always rebuild
		self.build_u('target')
		self.assertNotEqual(mtime, self.mtime('somefile'))
