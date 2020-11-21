from .util import *

class TestClean(TestCase):
	def setUp(self):
		super(TestClean, self).setUp()
		self.write('target.gup', echo_to_target('target contents'))
		self.symlink('target', 'manual_symlink')
		self.write('built_symlink.gup', BASH + 'ln -s target "$1"')
		self.write('source', 'plain src')
		self.write('source-that-was-target.gup', echo_to_target('ok'))
		self.write('nested/dir/target.gup', echo_to_target('ok'))
		self.mkdirp('scoped')
		os.symlink('../nested', self.path('scoped/sibling'))

		self.write('target-without-metadata.gup', echo_to_target('ok'))

		self.build_u(
			'source-that-was-target',
			'target-without-metadata',
			'target',
			'built_symlink',
			'nested/dir/target',
		)
		os.remove(self.path('source-that-was-target.gup'))
		os.remove(self.path('.gup/deps.target-without-metadata'))

		self.initial_files = self.list_root()
		assert '.gup' in self.initial_files

	def list_root(self):
		return os.listdir(self.path('.'))

	def test_removes_nothing_when___dry_run(self):
		self.build('--clean', '--dry-run')
		self.assertEqual(self.list_root(), self.initial_files)

	def test_fails_if_dry_run_or_force_are_not_given(self):
		self.assertRaises(SafeError, lambda: self.build('--clean'))

	def test_removes_from_nested_dir(self):
		self.build('--clean', '-f')
		self.assertFalse(self.exists('nested/dir/target'))

	def test_removes_targets_and_metadata(self):
		self.build('--clean', '-f')
		self.assertTrue(self.exists('source'))
		self.assertFalse(self.exists('target'))
		self.assertFalse(self.exists('.gup'))

	def test_removes_only_built_symlinks(self):
		self.build('--clean', '-f')
		self.assertFalse(self.lexists('built_symlink'))
		self.assertTrue(self.lexists('manual_symlink'))

	def test_doesnt_follow_symlinks(self):
		self.build('--clean', '-f', 'scoped')
		self.assertTrue(self.lexists('scoped/sibling'))
		self.assertTrue(self.exists('nested/dir/target'))
	
	def test_ignores_hidden_directories(self):
		self.write('.foo/foo.gup', echo_to_target('target contents'))
		self.build('.foo/foo')
		self.build('--clean', '-f')
		self.assertTrue(self.exists('.foo/.gup'))
	
	def test_removes_directory_targets(self):
		self.write('foo.gup', BASH + 'mkdir -p $1; touch $1/bar')
		self.write('.foo.gup', BASH + 'mkdir -p $1; touch $1/bar')
		self.build_u('foo')
		self.build_u('.foo')
		self.assertTrue(self.exists('foo/bar'))
		self.assertTrue(self.exists('.foo/bar'))

		self.build('--clean', '-f')
		self.assertFalse(self.exists('foo'))
		self.assertFalse(self.exists('.foo'))

	def test_removes_only_metadata_when___metadata(self):
		self.build('--clean', '-f', '--metadata')
		files_without_gup = self.initial_files[:]
		files_without_gup.remove('.gup')
		self.assertEqual(self.list_root(), files_without_gup)

	def test_leaves_targets_with_no_dep_information(self):
		# these might *not* be actual targets
		self.build('--clean', '-f')
		assert os.path.exists(self.path('source-that-was-target'))

	def test_leaves_targets_with_no_builder(self):
		# important - .dep info may be hanging around from
		# before this file became a source file
		self.build('--clean', '-f')
		assert os.path.exists(self.path('target-without-metadata'))

class TestCleanMultipleDirectories(TestCase):
	def setUp(self):
		super(TestCleanMultipleDirectories, self).setUp()
		self.write('target.gup', echo_to_target('target contents'))
		self.write('a/target.gup', echo_to_target('target contents'))
		self.write('b/target.gup', echo_to_target('target contents'))
		self.write('c/target.gup', echo_to_target('target contents'))
		self.build('-j4', 'target', 'a/target', 'b/target', 'c/target')

	def list_root(self):
		return os.listdir(self.path('.'))
	
	def test_cleans_only_the_given_directories(self):
		self.build('--clean', '-f', 'a', 'c')

		self.assertTrue(self.exists('.gup'))
		self.assertTrue(self.exists('target'))

		self.assertFalse(self.exists('a/.gup'))
		self.assertFalse(self.exists('a/target'))

		self.assertTrue(self.exists('b/.gup'))
		self.assertTrue(self.exists('b/target'))

		self.assertFalse(self.exists('c/.gup'))
		self.assertFalse(self.exists('c/target'))

