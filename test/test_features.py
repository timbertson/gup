from .util import *

class TestFeatures(TestCase):
	def test_reports_version(self):
		with open(os.path.join(os.path.dirname(__file__), '../VERSION')) as version_file:
			current_version = version_file.read().strip()
		assert current_version, "couldn't find current version"

		lines = self._build(["--features"])
		version_line = lines[0]
		self.assertEqual(version_line, 'version ' + current_version)
	
	@skipPermutations
	def test_ocaml_version_has_list_targets(self):
		exe = GUP_EXES[0]
		if not os.path.isabs(exe):
			from which import which
			exe = which(exe)
		is_ocaml = os.path.join("ocaml", "bin") in exe
		if not is_ocaml:
			assert os.path.join("python", "bin") in exe or os.path.join("test","bin") in exe, ("unknown exe: %s" % exe)
		self.assertEqual(has_feature("list-targets"), is_ocaml)
	
	def test_keep_failed(self):
		self.write("bad_c.gup", BASH + 'echo bad_c > "$1"; gup -u bad_b')
		self.write("bad_b.gup", BASH + 'echo bad_b > "$1"; gup -u bad_a')
		self.write("bad_a.gup", BASH + 'exit 1')
		code, lines = self.build("bad_c", '--keep-failed', throwing=False, include_logging=True)
		self.assertNotEqual(code, 0)
		error_lines = filter(lambda line: 'failed with exit status' in line, lines)
		error_lines = map(lambda line: line.split(' ',2)[-1].strip(), error_lines)
		error_lines = list(error_lines)

		# firstly, check that only extant files are reported
		self.assertEqual(error_lines, [
			'Target `bad_a` failed with exit status 1',
			'Target `bad_b` failed with exit status 2 (keeping %s for inspection)' % os.path.join('.gup', 'bad_b.out'),
			'Target `bad_c` failed with exit status 2 (keeping %s for inspection)' % os.path.join('.gup', 'bad_c.out'),
		])

		# then check their contents
		self.assertEqual(self.read('.gup/bad_b.out'), 'bad_b')
		self.assertEqual(self.read('.gup/bad_c.out'), 'bad_c')
