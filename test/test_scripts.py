from util import *
class TestScripts(TestCase):
	def test_interpreter(self):
		self.write('gup/all.gup', '#!./build abc\n# ...')
		self.write('gup/build', BASH + '(echo "target: $4"; echo "arg: $1") > "$3"')
		os.chmod(self.path('gup/build'), 0755)

		self.build('all')

		self.assertEquals(self.read('all'), 'target: all\narg: abc\n')

	def test_target_name_is_relative_to_gupfile_without_gup_dir(self):
		mkdirp(self.path('a/b'))
		self.write("gup/a/default.gup", echo_to_target('$2'))
		self.write("gup/a/nested/default.gup", echo_to_target('nested: $2'))
		self.write("gup/a/Gupfile", 'default.gup:\n\tb/c\nnested/default.gup:\n\tb/d')

		self.build('c', 'd', cwd='a/b')
		self.assertEquals(self.read('a/b/c'), 'b/c')
		self.assertEquals(self.read('a/b/d'), 'nested: ../b/d')
	
	def test_cwd_is_relative_to_target(self):
		self.write('gup/all.gup', BASH + 'mkdir -p foo; cd foo; gup -u bar')
		self.write('gup/foo/bar.gup', echo_to_target('ok'))

		self.build('all')

		self.assertEquals(self.read('foo/bar'), 'ok')

	def test_cwd_is_relative_to_matched_target_name_from_gupfile(self):
		mkdirp(self.path('a/b'))
		self.write("a/bc.gup", BASH + 'gup -u b/d; echo -n "$(basename $(pwd))" > $1')
		self.write("a/bd.gup", BASH + 'echo -n "$(basename $(pwd))" > $1')
		self.write("a/Gupfile", 'bc.gup:\n\tb/c\nbd.gup:\n\tb/d')

		self.build('c', cwd='a/b')
		self.assertEquals(self.read('a/b/c'), 'a')
		self.assertEquals(self.read('a/b/d'), 'a')
	
	def test_self_dependency_is_detected(self):
		self.write('foo.gup', BASH + 'echo ok > "$1"; gup -u foo')
		self.assertRaises(TargetFailed, lambda: self.build('foo'))

