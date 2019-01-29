from .util import *

@unittest.skipIf(not has_feature("list-targets"), "no --targets support")
class TestCompletion(TestCase):
	def test_empty_completions(self):
		self.assertEquals(self.completionTargets('dir'), [])

	def test_direct_completions(self):
		self.touch('root.gup')
		self.touch('dir/file1.gup')
		self.touch('dir/file2.gup')
		self.touch('dir/file3')

		self.assertEquals(
			self.completionTargets('dir'),
			['dir/file1','dir/file2'])

		self.assertEquals(
			self.completionTargets('.'),
			['./root'])

		self.assertEquals(
			self.completionTargets('./'),
			['./root'])

		self.assertEquals(
			self.completionTargets(),
			['root'])

	def test_multiple_completions_are_ignored(self):
		self.touch('dir/file1.gup')
		self.touch('dir/gup/file1.gup')

		self.assertEquals(
			self.completionTargets('dir'),
			['dir/file1'])
	
	def test_gup_dir(self):
		self.touch('gup/indirect/file1.gup')
		self.assertEquals(
			self.completionTargets('indirect'),
			['indirect/file1'])
	
	def test_sibling_gupfile_parsing(self):
		self.touch('file3')
		self.touch('file4')
		self.write('Gupfile', '''script:
			file1
			file2
			*3
		''')
		self.assertEquals(
			self.completionTargets(),
			['file1','file2','file3'])

	def test_excluded_gupfile_matches(self):
		self.touch('file1')
		self.touch('file2')
		self.write('Gupfile', '''script:
			file*
			!file2
		''')
		self.assertEquals(
			self.completionTargets(),
			['file1'])

	def test_concrete_matches_in_wildcard_dir(self):
		self.write('Gupfile', '''script:
			*/file1
			**/file2
		''')
		self.assertEquals(
			self.completionTargets('dir'),
			['dir/file1', 'dir/file2'])

		self.assertEquals(
			self.completionTargets('dir/subdir'),
			['dir/subdir/file2'])

	def test_gupfile_in_gupdir_parsing(self):
		self.touch('dir/file3')
		self.touch('dir/file4')
		self.touch('dir/file4')
		self.write('Gupfile', '''script:
			dir/file1
			dir/file2
			dir/*3
			**4
		''')
		self.assertEquals(
			self.completionTargets('dir/'),
			['dir/file1','dir/file2','dir/file3', 'dir/file4'])
	
	def test_multiple_gup_dirs(self):
		self.touch('dir/gup/file1.gup')
		self.touch('gup/dir/file2.gup')
		self.assertEquals(
			self.completionTargets('dir'),
			['dir/file1','dir/file2'])
	
	def test_multiple_gup_files(self):
		self.write('dir/gup/Gupfile', '''script:
			file1
		''')
		self.write('gup/Gupfile', '''script:
			dir/file2
		''')
		self.assertEquals(
			self.completionTargets('dir/'),
			['dir/file1','dir/file2'])


