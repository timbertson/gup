from util import *
class TestScripts(TestCase):
	def test_interpreter(self):
		self.write('gup/all.gup', '#!./build abc\n# ...')
		self.write('gup/build', BASH + '(echo "target: $4"; echo "arg: $1") > "$3"')
		os.chmod(self.path('gup/build'), 0755)

		self.build('all')

		self.assertEquals(self.read('all'), 'target: all\narg: abc\n')
