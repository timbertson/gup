from util import *

class TestDependencies(TestCase):
	def setUp(self):
		super(TestDependencies, self).setUp()
		self.write("dep.gup", BASH + 'gup -u counter; echo -n "COUNT: $(cat counter)" > "$1"')

	def test_rebuilds_on_dependency_change(self):
		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		self.write("counter", "2")
		self.build_u_assert("dep", "COUNT: 2")
	
	def test_doesnt_rebuild_unnecessarily(self):
		self.assertRaises(TargetFailed, lambda: self.build("dep"))

		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		mtime = self.mtime('dep')

		self.build_u("dep")
		self.assertEqual(self.mtime('dep'), mtime)
	
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
	
	def test_target_depends_on_gupfile(self):
		self.write('target.gup', echo_to_target('ok'))

		self.assertRebuilds('target', lambda: self.touch('target.gup'))

	def test_recursive_dependencies_include_gupfile(self):
		self.write('child.gup', echo_to_target('ok'))
		self.write('parent.gup', BASH + 'gup -u child; echo ok > $1')

		self.assertRebuilds('parent', lambda: self.touch('child.gup'))

	def test_gupfile_is_relative_to_target_not_cwd(self):
		self.write('target.gup', echo_to_target('ok'))
		self.assertRebuilds('target', lambda: self.touch('target.gup'))

		mtime = self.mtime('target')

		self.mkdirp('dir')
		self.build_u('../target', cwd='dir')
		self.assertEqual(self.mtime('target'), mtime)

	def test_target_depends_on_gupfile_location(self):
		self.write('gup/target.gup', echo_to_target('gup'))
		def move_gupfile():
			self.assertEqual(self.read('target'), 'gup')
			self.write('target.gup', echo_to_target('direct'))

		self.assertRebuilds('target', move_gupfile)
		self.assertEqual(self.read('target'), 'direct')

	def test_target_depends_on_gupfile_used(self):
		self.write('a.gup', echo_to_target('ok'))
		self.write('b.gup', echo_to_target('ok'))
		self.write('Gupfile', 'a.gup:\n\t*')

		def change_gupfile():
			self.write('Gupfile', 'b.gup:\n\t*')

		self.assertNotRebuilds('target', lambda: self.touch('Gupfile'))
		self.assertRebuilds('target', change_gupfile)
	
class TestAlwaysRebuild(TestCase):
	def test_always_rebuild(self):
		self.write('all.gup', echo_to_target('ok') + '; gup --always')
		self.assertRebuilds('all', lambda: None)

class TestNonexistentDeps(TestCase):
	def test_rebuilt_on_creation_of_dependency(self):
		self.write('all.gup', BASH + 'gup --ifcreate foo; echo 1 > $1')

		self.assertNotRebuilds('all', lambda: self.touch('bar'))
		self.assertRebuilds('all', lambda: self.touch('foo'))
		self.assertNotRebuilds('all', lambda: None)


class TestPsuedoTasks(TestCase):
	def test_treats_targets_without_output_as_always_dirty(self):
		self.write('target.gup', BASH + 'echo "updated" > somefile')

		self.build_u('target')
		self.assertFalse(os.path.exists(self.path('target')))
		mtime = self.mtime('somefile')

		# no output created - should always rebuild
		self.build_u('target')
		self.assertNotEqual(mtime, self.mtime('somefile'))
