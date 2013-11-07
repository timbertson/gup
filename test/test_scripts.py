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
		self.write("a/default.gup", echo_to_target('$2'))
		self.write("a/Gupfile", 'default.gup:\n\tb/c')

		self.build('c', cwd='a/b')
		self.assertEquals(self.read('a/b/c'), 'b/c')
	
	def test_cwd_is_relative_to_target(self):
		self.write('gup/all.gup', BASH + 'mkdir -p foo; cd foo; gup -u bar')
		self.write('gup/foo/bar.gup', echo_to_target('ok'))

		self.build('all')

		self.assertEquals(self.read('foo/bar'), 'ok')

	def test_cwd_is_relative_to_matched_target_name_from_gupfile(self):
		mkdirp(self.path('a/b'))
		self.write("a/default.gup", BASH + 'gup -u b/d; echo "$(basename $(pwd))" > $1')
		self.write("a/Gupfile", 'default.gup:\n\tb/*')

		self.build('c', cwd='a/b')
		self.assertEquals(self.read('a/b/c'), 'a')
		self.assertEquals(self.read('a/b/d'), 'a')
