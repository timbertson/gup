from util import *

class TestBasicRules(TestCase):
	def setUp(self):
		super(DobuildTests, self).setUp()
		self.write("default.gup", '#!/bin/bash\necho -n "$2" > "$1"')
		self.source_contents = "Don\t overwrite me!"
		self.write("source.txt", self.source_contents)

	def test_doesnt_overwrite_existing_file(self):
		self.assertRaises(Unbuildable, lambda: self.build("source.txt"))

		self.build_u("source.txt")
		self.assertEqual(self.read("source.txt"), self.source_contents)
	
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

