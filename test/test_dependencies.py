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

	def test_rebuilds_if___update_was_not_specified(self):
		self.write("counter", "1")

		target = 'dep'
		self.build(target)
		mtime = self.mtime(target)
		self.build(target)
		self.assertNotEqual(self.mtime(target), mtime, "target %s didn't get rebuilt" % (target,))

	def test_rebuilds_if_file_was_modified_outside_gup(self):
		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		self.assertRebuilds('dep', lambda: self.touch('dep'))
		self.assertRebuilds('dep', lambda: self.touch('counter'))
	
	def test_doesnt_rebuild_unnecessarily(self):
		self.write("counter", "1")
		self.build_u_assert("dep", "COUNT: 1")
		mtime = self.mtime('dep')

		self.build_u("dep")
		self.assertEqual(self.mtime('dep'), mtime)

	def test_fully_pathed_dependencies(self):
		self.write('input', '1')
		self.write("counter.gup", BASH + 'gup -u $PWD/input; echo 1 > "$1"')
		self.write("dep.gup", BASH + 'gup -u $PWD/counter; echo -n "COUNT: $(cat counter)" > "$1"')
		
		self.assertRebuilds('dep', lambda: self.touch('input'))
		self.assertNotRebuilds('dep', lambda: None)

	def test_deps_of_fully_pathed_targets(self):
		# regression: FileDependency checked mtime of `base`
		# (instead of `path`) when `base` is absolute
		self.write('input', '1')
		time.sleep(0.1)
		self.write("counter.gup", BASH + 'gup -u input; echo 1 > "$1"')
		
		self.assertNotRebuilds(os.path.join(self.ROOT, 'counter'), lambda: None)
	
	def test_dependencies_use_correct_path_when_builder_is_not_in_same_dir_as_target(self):
		self.write('src/input', '1')
		self.write('build.sh', BASH + 'gup -u src/input; echo 1 > "$1"')
		self.write('Gupfile', 'build.sh:\n\tbuild/*')

		self.assertRebuilds('build/output', lambda: self.touch('src/input'))
		self.assertNotRebuilds('build/output', lambda: None)

	def test_tracks_dependencies_outside_working_tree(self):
		import tempfile
		with tempfile.NamedTemporaryFile() as dep:
			self.write("target.gup", BASH + 'gup -u "%s"; touch "$1"' % dep.name)
			self.assertNotRebuilds('target', lambda: None)
			self.assertRebuilds('target', lambda: self.touch(dep.name))
	
	def test_trying_to_build_source_fails(self):
		self.assertRaises(SafeError, lambda: self.build("dep"))

	def test_builder_listed_in_gupfile_is_buildable_explicitly(self):
		self.write('actual_builder', echo_to_target("built"))
		self.write('builder.gup', BASH + 'cp actual_builder "$1"')
		self.write('Gupfile', 'builder:\n\ttarget\nbuilder.gup:\n\tbuilder')
		self.build_u('target')

		self.assertEqual(self.read('target'), 'built')

	def test_Gupfile_and_gup_scripts_are_not_buildable_by_gup_scripts(self):
		self.write('Gupfile.gup', echo_to_target('you shouldn\'t be here!'))
		self.write('target.gup.gup', echo_to_target('you shouldn\'t be here!'))

		self.assertRaises(Unbuildable, lambda: self.build("Gupfile"))
		self.assertRaises(Unbuildable, lambda: self.build("target.gup"))

	def test_Gupfile_and_gup_scripts_are_not_buildable_by_wildcard_rules(self):
		gupfile_contents = 'build-anything:\n\t*'
		gupscript_contents = echo_to_target('ok')
		self.write('Gupfile', gupfile_contents)
		self.write('target.gup', gupscript_contents)
		self.write('build-anything', echo_to_target('built-by-anything'))

		self.build_u('Gupfile')
		self.assertEqual(self.read('Gupfile'), gupfile_contents)
		
		self.build_u('target.gup')
		self.assertEqual(self.read('target.gup'), gupscript_contents)
		
		self.build_u('target', 'target.goop')
		self.assertEqual(self.read('target.goop'), 'built-by-anything')
		self.assertEqual(self.read('target'), 'ok')
	
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
	
	def test_transitive_target_dependencies_are_pathed_correctly(self):
		# Written to cover a discovered bug in which everything built properly,
		# but re-building a/foo (which depended) on a/bar would check whether ./bar
		# needs rebuilding, not a/bar
		self.write("a/counter.gup", BASH + 'gup -u counter2; echo -n "$(expr "$(cat counter2)" + 1)" > $1')
		self.write("a/counter2.gup", BASH + 'gup -u counter3; echo -n "$(expr "$(cat counter3)" + 1)" > $1')
		self.write("dep.gup", BASH + 'gup -u a/counter; echo -n "COUNT: $(cat a/counter)" > "$1"')

		self.write("a/counter3", "1")
		self.build_u('dep')
		self.assertEqual(self.read('dep'), 'COUNT: 3')
		self.assertEqual(self.read("a/counter"), "3")

		self.assertNotRebuilds('dep', lambda: None)

		self.write("a/counter3", "2")
		self.build_u("dep")
		self.assertEqual(self.read("dep"), "COUNT: 4")
		self.assertEqual(self.read("a/counter"), "4")

	
	def test_target_depends_on_gupfile(self):
		self.write('target.gup', echo_to_target('ok'))

		self.assertRebuilds('target', lambda: self.touch('target.gup'))
	
	def test_depend_on_file_with_spaces(self):
		self.write('target.gup', echo_file_contents('a b'))
		self.write('a b', 'a b c!')
		self.build_assert('target', 'a b c!')
		self.assertRebuilds('target', lambda: self.touch('a b'))

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

class TestCyclicDependencies(TestCase):
	def setUp(self):
		super(TestCyclicDependencies, self).setUp()

	def test_cannot_build_self(self):
		self.write("self.gup", BASH + 'gup -u self')
		self.assertRegexpMatches(self.buildErrors('self')[0],
			re.compile('Target `.*self` attempted to build itself'))

	def test_cannot_build_self_indirectly(self):
		self.mkdirp("dir")
		self.write("indirect-self.gup", BASH + 'gup -u dir/../indirect-self')

		self.assertRegexpMatches(self.buildErrors('indirect-self')[0],
			re.compile('Target `.*indirect-self` attempted to build itself'))

	def test_can_build_a_symlink_to_self(self):
		self.write("symlink-dest.gup", BASH + 'gup -u symlink; touch $1')
		self.write("symlink.gup", BASH + 'ln -s symlink-dest "$1"')

		target = 'symlink-dest'
		link = 'symlink'
		self.build(target)
		self.assertEqual(os.readlink(self.path(link)), target)
		self.build(target)

class TestDirtyCheck(TestCase):
	def assertDirty(self, target, expected):
		code, lines = self.build('--dirty', target, throwing = False)
		self.assertEqual(code, 0 if expected else 1)
		self.assertEqual(lines, [])

	def test_simple_dependency_dirty(self):
		self.write('file.gup', echo_file_contents('input'))
		self.write('input', '1')
		self.build('file')

		self.touch('input')
		self.assertDirty('file', True)

	def test_simple_dependency_clean(self):
		self.write('file.gup', echo_file_contents('input'))
		self.write('input', '1')
		self.build('file')

		self.assertDirty('file', False)

	def test_unbuilt_target(self):
		self.write('file.gup', echo_file_contents('input'))
		self.assertDirty('file', True)

	def test_pseudo_target(self):
		self.write('target.gup', BASH + 'true')
		self.build('target')
		self.assertDirty('target', True)

	def test_checksum_dependency(self):
		self.write('checksum.gup', echo_file_contents('input-cs'))
		self.write('input-cs.gup', echo_file_contents('input') + '; gup --contents "$1"')
		self.write('input', '1')
		self.build('checksum')

		self.assertDirty('checksum', False)

		def action():
			self.touch('input')
			# the above should make --dirty return true, even though
			# the target doesn't really need to be rebuilt
			# (because without building input-cs, we can't know whether
			# the target is actually dirty)
			self.assertDirty('checksum', True)
		self.assertNotRebuilds('checksum', action)

class TestSymlinkDependencies(TestCase):
	def test_dependencies_outside_symlink(self):
		self.write('src/build/foo.gup', BASH + 'gup -u '+self.ROOT + '/input; touch $1')
		self.symlink('src/build', 'build')
		self.touch('input')
		self.build('build/foo')

		self.assertRebuilds('build/foo', lambda: self.touch('input'))
		self.assertNotRebuilds('build/foo', lambda: None)

	def test_builds_symlink_dest_if_symlink_is_not_itself_buildable(self):
		self.write('dest.gup', BASH + 'touch $1')
		self.symlink('dest', 'link')
		self.build('link')

		self.assertRebuilds('link', lambda: self.touch('dest.gup'), mtime_file='dest')

	def test_resolves_relative_symlinks(self):
		self.write('base/dir/dest.gup', BASH + 'touch $1')
		self.symlink('dir/dest', 'base/link')
		self.build('base/link')

		self.assertRebuilds('base/link', lambda: self.touch('base/dir/dest.gup'), mtime_file='base/dir/dest')

	def test_depends_on_each_file_in_symlink_chain(self):
		self.write('target.gup', echo_file_contents('dir1/contents'))
		self.write('concrete1/contents', '1')
		self.write('concrete2/contents', '2')
		self.write('concrete3/contents', '3')
		self.symlink('dir2', 'dir1')
		self.symlink('dir3', 'dir2')
		self.symlink('concrete1', 'dir3')

		self.assertNotRebuilds('target', lambda: None)
		self.assertEqual(self.read('target'), '1')

		self.assertRebuilds('target', lambda: self.symlink('concrete2', 'dir3', force=True))
		self.assertEqual(self.read('target'), '2')

		self.assertRebuilds('target', lambda: self.symlink('concrete3', 'dir2', force=True))
		self.assertEqual(self.read('target'), '3')

	def test_resolves_non_normalized_symlinks(self):
		# i.e. those where a symlink's `../` component is resolved from an intermediate
		# symlink target, not from the original link
		self.write('target.gup', BASH + 'gup -u bin/tsc; cat bin/tsc > $1')
		self.mkdirp('prefix/libexec')
		self.mkdirp('prefix/bin')
		self.symlink('prefix/bin', 'bin')
		self.symlink('../libexec/tsc', 'prefix/bin/tsc')
		self.write('prefix/libexec/tsc', 'tsc')
		self.write('prefix/libexec/tsc2', 'tsc2')

		self.assertNotRebuilds('target', lambda: None)
		self.assertRebuilds('target', lambda: self.touch('prefix/libexec/tsc'))
		self.assertEqual(self.read('target'), 'tsc')

		self.assertRebuilds('target', lambda: self.symlink('../libexec/tsc2', 'prefix/bin/tsc', force=True))
		self.assertEqual(self.read('target'), 'tsc2')

	def test_builds_symlink_only_if_symlink_is_buildable(self):
		self.write('dest.gup', BASH + 'echo "built by dest.gup" > $1')
		self.write('dest', '(plain dest)')
		self.write('link.gup', BASH + 'ln -s dest $1')
		self.build_assert('link', '(plain dest)')
		self.assertTrue(os.path.islink(self.path('link')), "link is not a symlink!")

		self.assertRebuilds('link', lambda: self.touch('link.gup'))
		self.assertNotRebuilds('link', lambda: self.touch('dest.gup'), mtime_file='dest')

	def test_rebuilds_if_builder_behind_symlink_changes(self):
		self.write('real_builder.gup', echo_to_target('1'))
		self.symlink('real_builder.gup', 'target.gup')
		self.assertRebuilds('target', lambda: self.touch('real_builder.gup'))

	def test_rebuilds_if_builder_symlink_changes(self):
		self.write('real_builder.gup', echo_to_target('1'))
		self.write('second_builder.gup', echo_to_target('2'))
		self.symlink('real_builder.gup', self.path('target.gup'))
		self.build_assert('target', '1')

		def change_referent():
			self.unlink('target.gup')
			self.symlink('second_builder.gup', 'target.gup')

		self.assertRebuilds('target', change_referent)
		self.assertEqual(self.read('target'), '2')

	def test_rebuilds_if_dependency_behind_symlink_changes(self):
		self.write('dep_dest', '1');
		self.symlink('dep_dest', 'dep')
		self.write('target.gup', echo_file_contents('dep'))
		self.assertRebuilds('target', lambda: self.touch('dep_dest'))

	def test_rebuilds_if_checksummed_dependency_behind_symlink_changes(self):
		self.write('contents', '1')
		self.write('dep1.gup', BASH + 'gup -u contents; cat contents > "$1"; gup --contents "$1"');
		self.symlink('dep1', 'dep')
		self.write('target.gup', echo_file_contents('dep'))

		self.assertRebuilds('target', lambda: self.write('contents', '2'))
		self.assertNotRebuilds('target', lambda: self.write('contents', '2'))

	def test_rebuilds_if_dependency_symlink_changes(self):
		self.write('dep1', '1');
		self.write('dep2', '2');
		self.symlink('dep1', 'dep')
		self.write('target.gup', echo_file_contents('dep'))
		self.build_assert('target', '1')

		def change_referent():
			self.unlink('dep')
			self.symlink('dep2', 'dep')
		self.assertRebuilds('target', change_referent)
		self.assertEqual(self.read('target'), '2')

	IFCREATE_LINK_SCRIPT = '''
			if [ ! -e link ]; then
				gup --ifcreate link;
			fi
			echo 1 > "$1"
	'''

	def test_ifcreate_on_broken_link(self):
		self.write('target.gup', BASH + self.IFCREATE_LINK_SCRIPT)
		self.symlink('dest', 'link')
		self.assertNotRebuilds('target', lambda: None)
		self.assertRebuilds('target', lambda: self.touch('dest'))

	def test_ifcreate_on_any_chain_in_broken_link(self):
		self.write('target.gup', BASH + self.IFCREATE_LINK_SCRIPT)
		self.symlink('link2', 'link')
		self.symlink('dest', 'link2')
		self.assertNotRebuilds('target', lambda: None)
		self.assertRebuilds('target', lambda: self.touch('dest'))
	
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
		self.write('all.gup', BASH + 'if [ ! -f foo ]; then gup --ifcreate foo; fi; echo 1 > $1')

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

	def test_recursive_dependencies_are_still_checked_when_checksum_dependency_is_unchanged(self):
		self.write('parent.gup', self.read('parent.gup') + '\ngup -u other_dep')
		self.write('other_dep.gup', echo_file_contents('other_dep_child'))
		self.write('other_dep_child', '1')

		self.assertRebuilds('parent', lambda: self.touch('other_dep_child'))

	def test_parent_of_checksum_is_rebult_if_checksum_contents_changes(self):
		self.assertRebuilds('parent', lambda: self.write('input', 'ok2'))

	def test_parent_of_checksum_does_not_need_rebuilding_if_checksum_state_is_missing(self):
		change = lambda: os.remove(self.path('.gup/deps.cs'))
		self.assertRebuilds('cs', change)
		self.assertNotRebuilds('parent', change)

	@skipPermutations
	def test_checksum_accepts_a_number_of_files_instead_of_stdin(self):
		self.write('firstline', 'line1')
		self.write('secondline', 'line2')
		self.write('cs_onefile.gup', BASH + 'gup --always; gup --contents input')
		self.write('cs_twofile.gup', BASH + 'gup --always; gup --contents firstline secondline')

		def assertChecksumChanges(target, f):
			self.build_u(target)
			cs1 = get_checksum(target)
			f()
			self.build_u(target)
			cs2 = get_checksum(target)
			self.assertNotEquals(cs1, cs2)

		def assertNotChecksumChanges(target, f):
			self.build_u(target)
			cs1 = get_checksum(target)
			f()
			self.build_u(target)
			cs2 = get_checksum(target)
			self.assertEquals(cs1, cs2)

		def get_checksum(target):
			lines = self.read('.gup/deps.%s' % target).splitlines()
			for line in lines:
				if line.startswith('checksum: '):
					return line.split(' ', 1)[1]
			raise ValueError("no checksum in %r" % lines,)

		assertChecksumChanges('cs', lambda: self.write('input', 'ok2'))
		assertNotChecksumChanges('cs', lambda: None)

		assertChecksumChanges('cs_onefile', lambda: self.write('input', 'ok3'))
		assertNotChecksumChanges('cs_onefile', lambda: None)

		assertChecksumChanges('cs_twofile', lambda: self.write('firstline', 'new line1'))
		assertChecksumChanges('cs_twofile', lambda: self.write('secondline', 'new line2'))
		assertNotChecksumChanges('cs_twofile', lambda: None)

	def test_parent_of_checksum_is_rebult_if_child_stops_being_checksummed(self):
		self.build_u('parent')
		self.assertRebuilds('parent', lambda: self.write('cs.gup', echo_file_contents('input')))

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

	def test_checksummed_target_with_no_output_causes_parent_to_rebuild(self):
		self.write('parent.gup', BASH + 'gup -u child; echo ok > $1')
		self.write('child.gup', BASH + 'gup --always; echo $$-$RANDOM | gup --contents')
		self.assertRebuilds('parent', lambda: None)

	def test_checksummed_target_with_no_output_but_consistent_checksum_does_not_cause_rebuild(self):
		self.write('parent.gup', BASH + 'gup -u child; echo ok > $1')
		self.write('child.gup', BASH + 'gup --always; echo 1 | gup --contents')
		self.assertNotRebuilds('parent', lambda: None)

class TestVersion(TestCase):
	def write_deps(self, lines):
		self.write('.gup/deps.target', '\n'.join(lines))

	def write_old_deps(self):
		self.write_deps(['version: 0', 'some_old_key: xyz'])

	def test_overwrites_and_rebuilds_if_deps_are_a_different_version(self):
		self.write('target.gup', echo_to_target('hello'))
		self.assertRebuilds('target', self.write_old_deps)

	def test_overwrites_and_rebuilds_if_deps_are_invalid(self):
		self.write('target.gup', echo_to_target('hello'))
		self.assertRebuilds('target', lambda: self.write_deps(['not_even_valid']))
		from gup import state
		self.assertRebuilds('target', lambda: self.write_deps([
			'version: %s' % state.Dependencies.FORMAT_VERSION,
			'something_else: 123'
		]))
