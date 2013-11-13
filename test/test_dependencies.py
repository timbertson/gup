from .util import *

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
		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		mtime = self.mtime('dep')

		self.build_u("dep")
		self.assertEqual(self.mtime('dep'), mtime)
	
	def test_trying_to_build_source_fails(self):
		self.assertRaises(SafeError, lambda: self.build("dep"))
	
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
	
	def test_target_dependencies_are_ignored_if_target_becomes_source(self):
		self.write('build_a.gup', echo_to_target('target') + '; gup -u b')
		self.write('b', 'dependency')
		self.write('Gupfile', 'build_a.gup:\n\ta')
		self.build('a')

		self.assertRebuilds('a', lambda: self.touch('b'))

		self.write('Gupfile', 'build_a.gup:\n\tnothing')

		self.assertNotRebuilds('a', lambda: self.touch('b'))
	
class TestAlwaysRebuild(TestCase):
	def test_always_rebuild(self):
		self.write('all.gup', echo_to_target('ok') + '; gup --always')
		self.assertRebuilds('all', lambda: None)

	def test_always_target_is_built_at_most_once_in_a_given_run(self):
		self.write('count', '0')
		self.write('always.gup', echo_to_target('ok') + '; count="$(expr $(cat count) + 1)"; echo $count > count; gup --always')
		self.write('dep1.gup', echo_file_contents('always'))
		self.write('dep2.gup', echo_file_contents('always'))

		self.build_u('dep1', 'dep2')
		self.assertEqual(self.read('dep1'), 'ok')
		self.assertEqual(self.read('dep2'), 'ok')
		self.assertEqual(self.read('count'), '1')

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

class TestChecksums(TestCase):
	def setUp(self):
		super(TestChecksums, self).setUp()
		self.write('input', 'ok')
		self.write('cs.gup', echo_file_contents('input') + '; cat $1 | gup --contents')
		self.write('parent.gup', echo_file_contents('cs'))

	def test_checksum_task_is_only_built_if_inputs_are_modified(self):
		self.assertRebuilds('cs', lambda: self.touch('input'))
		self.assertNotRebuilds('cs', lambda: None)

	def test_parent_of_checksum_is_not_rebult_if_checksum_remains_the_same(self):
		self.build('parent')

		csm = self.mtime('cs')

		self.assertNotRebuilds('parent', lambda: self.touch('input'), built=True)

		self.assertTrue(self.mtime('cs') > csm, "`cs` target not rebuilt")

	def test_parent_of_checksum_is_rebult_if_checksum_contents_changes(self):
		self.assertRebuilds('parent', lambda: self.write('input', 'ok2'))

	def test_nested_checksum_tasks_are_handled(self):
		self.write('parent.gup', BASH + 'gup -u cs; cat cs > $1; cat parent_stamp | gup --contents')
		self.write('parent_stamp', 'CONST')
		self.write('grandparent.gup', echo_file_contents('parent'))
		def collect_mtimes():
			t = {}
			for target in ['input', 'cs', 'parent', 'grandparent']:
				t[target] = self.mtime(target)
			return t

		self.build_u('grandparent')
		times = collect_mtimes()

		self.build_u('grandparent')
		# nothing should have rebuilt:
		self.assertEqual(times, collect_mtimes())

		self.write('input', 'ok2')
		self.build_u('grandparent')

		times2 = collect_mtimes()
		for target in ['input', 'cs', 'parent']:
			self.assertTrue(times2[target] > times[target], "expected target %s to be rebuilt" % target)

		for target in ['grandparent']:
			self.assertEqual(times2[target], times[target], "expected target %s not to be rebuilt" % target)