from .util import *

class TestBasicRules(TestCase):
	def setUp(self):
		super(TestBasicRules, self).setUp()
		self.write("default.gup", echo_to_target('$2'))
		self.source_contents = "Don't overwrite me!"
		self.write("source.txt", self.source_contents)

	def env_with_path(self, p):
		env = os.environ.copy()
		env['PATH'] = self.path(p) + ':' + os.environ.get('PATH', '')
		return env

	def test_doesnt_overwrite_existing_file(self):
		self.assertRaises(SafeError, lambda: self.build("source.txt"))

		self.build_u("source.txt")
		self.assertEqual(self.read("source.txt"), self.source_contents)

	def test_fails_on_updating_nonexitent_file(self):
		self.assertRaises(Unbuildable, lambda: self.build_u("nonexistent.txt"))

	@skipPermutations
	def test_only_creates_new_files_matching_pattern(self):
		self.assertRaises(Unbuildable, lambda: self.build("output.txt"))

		self.write("Gupfile", "default.gup:\n\toutput.txt\n\tfoo.txt")
		self.build("output.txt")
		self.build("foo.txt")
		self.assertEqual(self.read("output.txt"), "output.txt")

		self.write("Gupfile", "default.gup:\n\tf*.txt")
		self.assertRaises(Unbuildable, lambda: self.build("output.txt"))
		self.build("foo.txt")
		self.build("far.txt")

	def test_exclusions(self):
		self.write("Gupfile", "default.gup:\n\t*.txt\n\n\t!source.txt")
		self.build("output.txt")
		self.assertRaises(Unbuildable, lambda: self.build("source.txt"))
		self.assertEqual(self.read("source.txt"), self.source_contents)

	@unittest.skipIf(IS_WINDOWS, 'hard to test on windows')
	def test_builder_from_PATH(self):
		self.write('Gupfile', "!write-text-file:\n\t*.txt")
		self.write_executable('bin/write-text-file', BASH + 'echo "bin wrote $2" > "$1"')
		self.write_executable('bin2/write-text-file', BASH + 'echo "bin2 wrote $2" > "$1"')
		env_with_bin = self.env_with_path('bin')
		env_with_bin2 = self.env_with_path('bin2')

		ret, lines = self.build('output.txt', throwing=False, include_logging=True)

		# without PATH, it shouldn't build:
		self.assertNotEqual(ret, 0)
		lines = lines[-2:]
		err, info = lines
		self.assertEqual(err.strip('# '), 'ERROR Build command not found on PATH: write-text-file')
		self.assertRegexpMatches(info.strip(), '\(specified in .*Gupfile\)')

		# depends on script mtime
		self.build_assert('output.txt', 'bin wrote output.txt', env=env_with_bin)
		self.assertRebuilds('output.txt', lambda: self.touch('bin/write-text-file'), env=env_with_bin)

		# depends on which PATH entry is used
		mutable_env = env_with_bin.copy()
		self.assertRebuilds('output.txt', lambda: mutable_env.update(env_with_bin2), env=mutable_env)
		self.assertEqual(self.read('output.txt'), 'bin2 wrote output.txt')

	def test_builder_with_args(self):
		self.write('Gupfile', "!write-text-file --uppercase:\n\t*.txt")
		self.skipTest('TODO')

	def test_PATH_builder_cwd(self):
		self.write('src/Gupfile', "!write-text-file:\n\t*.txt")
		self.write_executable('bin/write-text-file', BASH + 'echo "wrote $2 from $(pwd)" > "$1"')
		env_with_bin = self.env_with_path('bin')
		self.build_assert('src/output.txt', 'wrote output.txt from ' + self.path('src'), env=env_with_bin)
	
	def test_runs_all_target_by_default(self):
		self.write('all.gup', echo_to_target('1'))
		self.build()
		self.assertEqual(self.read('all'), '1')

class TestGupdirectory(TestCase):
	def test_gupdir_is_search_target(self):
		self.write("gup/base.gup", BASH + 'echo -n "base" > "$1"')
		self.build('base')
		self.assertEqual(self.read('base'), 'base')
	
	def test_multiple_gup_dirs_searched(self):
		self.write("a/gup/b/c.gup", echo_to_target('c'))
		# shadowed by the above rule
		self.write("gup/a/b/c.gup", echo_to_target('wrong c'))

		self.write("gup/a/b/d.gup", echo_to_target('d'))

		self.build_assert('a/b/c', 'c')
		self.build_assert('a/b/d', 'd')

	def test_patterns_match_against_path_from_gupfile(self):
		self.write("a/default.gup", echo_to_target('ok'))
		self.write("a/Gupfile", 'default.gup:\n\tb/*/d')

		self.build_assert('a/b/c/d', 'ok')
		self.build_assert('a/b/xyz/d', 'ok')
		self.assertRaises(Unbuildable, lambda: self.build("x/b/cd"))
	
	def test_leaves_nothing_for_unbuildable_target(self):
		self.assertRaises(Unbuildable, lambda: self.build("a/b/c/d"))
		self.assertEquals(os.listdir(self.ROOT), [])

	def test_gupfile_patterns_ignore_gup_dir(self):
		self.write("gup/a/default.gup", echo_to_target('ok'))
		self.write("gup/a/Gupfile", 'default.gup:\n\tb/*/d')

		self.build_assert('a/b/c/d', 'ok')
		self.build_assert('a/b/xyz/d', 'ok')
		self.assertRaises(Unbuildable, lambda: self.build("x/b/cd"))
	
	def test_gupfile_may_specify_a_non_local_script(self):
		self.write("gup/a/default.c.gup", echo_to_target('$2, called from $(pwd)'))
		self.write('gup/a/b/Gupfile', '../default.c.gup:\n\t*.c')

		self.assertRaises(Unbuildable, lambda: self.build('a/foo.c'))
		self.build_assert('a/b/foo.c', 'foo.c, called from ' + self.path('a/b'))

	def test_build_script_outside_gup_dir(self):
		self.write("default.gup", echo_to_target('$2, called from "$(pwd)"'))
		self.write("gup/default.gup", echo_to_target('$2, called from gup dir "$(pwd)"'))
		self.write('gup/bin/Gupfile', '../../default.gup:\n\tfoo\n../default.gup:\n\tbar')

		self.build_assert('bin/foo', 'foo, called from ' + self.path('bin'))
		self.build_assert('bin/bar', 'bar, called from gup dir ' + self.path('bin'))

class TestBuildableCheck(TestCase):
	def test_indicates_buildable_file(self):
		self.write('Gupfile', 'builder:\n\ta')
		self.touch('builder')
		self.touch('b.gup')
		self.symlink('b', 'link_to_b')
		self.build('--buildable', 'a')
		self.build('--buildable', 'b')
		status, _lines = self.build('--buildable', 'link_to_b', throwing=False)
		self.assertEqual(status, 1)

	def test_returns_1_when_file_is_not_buildable(self):
		self.assertRaises(SafeError, lambda: self.build('--buildable', 'target'), message='gup failed with status 1')

	def test_returns_2_when_there_was_an_error(self):
		self.write('Gupfile', 'builder:\n\ta')
		# gupfile matched, but builder not found
		self.assertRaises(SafeError, lambda: self.build('--buildable', 'a'), message='gup failed with status 2')
	
	def test_doesnt_build_second_target_if_first_fails(self):
		self.write("a.gup", BASH + "echo a > $2; exit 1")
		self.write("b.gup", BASH + "echo b > $2; exit 1")
		self.assertRaises(SafeError, lambda: self.build("a","b"))
		self.assertEqual(self.read("a"), "a")
		self.assertFalse(self.exists("b"))

class TestDirectoryTargets(TestCase):
	def test_trailing_slashes_are_ignored_in_target_name(self):
		self.write('dir.gup', BASH + 'mkdir -p $1; echo ok > $1/hello')
		self.build_u('dir' + os.path.sep)
		self.assertEqual(self.read('dir/hello'), 'ok')
	
	def test_relative_paths_are_supported_from_within_target(self):
		self.write('dir.gup', BASH + 'mkdir -p $1; echo ok > $1/hello; mkdir $1/child')
		self.build_u('dir' + os.path.sep)
		self.build_u('.' + os.path.sep, cwd=self.path('dir'))
		self.build_u('./' + os.path.sep, cwd=self.path('dir'))
		self.build_u('../' + os.path.sep, cwd=self.path('dir/child'))
		self.build_u('..' + os.path.sep, cwd=self.path('dir/child'))
		self.assertEqual(self.read('dir/hello'), 'ok')
