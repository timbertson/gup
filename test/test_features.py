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
