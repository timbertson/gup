from .util import *
def _tmp_output_files(self):
	meta_files = os.listdir(self.path('.gup'))
	meta_files = filter(lambda f: not (f.endswith('.lock') or f.endswith('.deps')), meta_files)
	return list(meta_files)

class TestInterpreter(TestCase):
	@unittest.skipIf(IS_WINDOWS, 'posix')
	def test_interpreter_relaive_to_build_script(self):
		self.write('gup/all.gup', '#!./build abc\n# ...')
		self.write('gup/build', '#!/bin/bash\nset -eu\n' + '(echo "target: $4"; echo "arg: $1") > "$3"')
		os.chmod(self.path('gup/build'), 0o755)

		self.build('all')

		self.assertEquals(self.read('all'), 'target: all\narg: abc')

	def test_interpreter_resolution(self):
		self.write('build/relative.gup', '#!../scripts/run')
		self.write('build/pathed.gup', '#!my-build-script')

		self.write('scripts/run', '#!/bin/bash\necho "BASH $1" > "$2"')
		os.chmod(self.path('scripts/run'), 0o755)
		self.write('scripts/run.cmd', 'echo CMD %1 > "%2"')

		self.write('bin/my-build-script', '#!/bin/bash\necho "BASH $1" > "$2"')
		os.chmod(self.path('bin/my-build-script'), 0o755)
		self.write('bin/my-build-script.cmd', 'echo CMD %1 > "%2"')

		env = os.environ.copy()
		env['PATH'] = os.pathsep.join([self.path('bin'), env['PATH']])
		interp = 'CMD' if IS_WINDOWS else 'BASH'

		self.build('build/relative', 'build/pathed', env=env)

		self.assertEquals(self.read('build/relative').lower(), ' '.join([interp, self.path(os.path.join('build', 'relative.gup'))]).lower())
		self.assertEquals(self.read('build/pathed').lower(),   ' '.join([interp, self.path(os.path.join('build', 'pathed.gup'))]).lower())
	
	def test_fallback_if_path_to_env_is_missing(self):
		# For windows compatibility and other weird setups.
		# Currently we special-case this to basename=='env', but
		# this may be relaxed in the future if needed
		self.write('env.gup', '#!/var/not/really/env bash\necho 1 > $1')
		self.build_assert('env', '1')

		self.write('not_env.gup', '#!/var/not/really/not-env bash\necho 1')
		self.assertRaises(SafeError, lambda: self.build('not_env'))

class TestScripts(TestCase):
	def test_target_name_is_relative_to_gupfile_without_gup_dir(self):
		mkdirp(self.path('a/b'))
		self.write("gup/a/default.gup", echo_to_target('$2'))
		self.write("gup/a/nested/default.gup", echo_to_target('nested: $2'))
		self.write("gup/a/Gupfile", 'default.gup:\n\tb/c\nnested/default.gup:\n\tb/d')

		self.build('c', 'd', cwd='a/b')
		self.assertEquals(self.read('a/b/c'), os.path.join('b', 'c'))
		self.assertEquals(self.read('a/b/d'), 'nested: ' + os.path.join('..', 'b', 'd'))

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
		self.assertRaises(SafeError, lambda: self.build('foo'))

	def test_directory_script_is_re_run_if_dependencies_change(self):
		self.write('dir.gup', BASH + 'gup -u file; mkdir -p "$1"; cp file "$1/"; touch "$1"')
		self.write('file', 'filecontents')

		self.build('dir')
		self.assertTrue(os.path.isdir(self.path('dir')))
		self.assertEquals(self.read('dir/file'), 'filecontents')

		self.write('file', 'filecontents2')
		self.build_u('dir')
		self.assertEquals(self.read('dir/file'), 'filecontents2')

	def test_directory_and_file_targets_can_replace_each_other(self):
		self.write('dir.gup', BASH + 'mkdir "$1"; echo 1 > $1/file')
		self.write('file.gup', echo_to_target('file'))

		self.build('dir', 'file')
		self.assertTrue(os.path.isdir(self.path('dir')))
		self.assertTrue(os.path.isfile(self.path('file')))

		self.write('dir.gup', echo_to_target('file_now'))
		self.write('file.gup', BASH + 'mkdir "$1"; echo 1 > $1/file')
		self.build_u('dir', 'file')

		self.assertTrue(os.path.isfile(self.path('dir')))
		self.assertTrue(os.path.isdir(self.path('file')))
	
	def test_cleans_up_file_if_build_fails(self):
		self.write('file.gup', BASH + 'echo hello > "$1"; exit 1')
		self.assertRaises(SafeError, lambda: self.build('file'))
		self.assertEquals(_tmp_output_files(self), [])

	def test_cleans_up_directory_if_build_fails(self):
		self.write('dir.gup', BASH + 'mkdir "$1"; echo hello > "$1"/file; exit 1')
		self.assertRaises(SafeError, lambda: self.build('dir'))
		self.assertEquals(_tmp_output_files(self), [])
	
	def test_removes_output_path_before_building(self):
		# we can't always ensure that this gets cleaned up from a previous run,
		# so just make sure it's deleted before we try to build into it
		self.mkdirp('.gup/dir.out')
		self.write('dir.gup', BASH + '[ ! -e "$1" ]; mkdir "$1"; echo "$1" > "$1/path"')
		self.build('dir')
		with open(self.path('dir/path')) as p:
			target_path = p.read().strip()

		os.makedirs(target_path)
		readonly_path = os.path.join(target_path, 'readonly_file')
		with open(readonly_path, 'w') as f:
			pass
		os.chmod(readonly_path, 0o444)

		# build will fail if $1 already exists
		self.build('dir')

	def test_deletes_target_if_build_succeeds_but_generates_no_output(self):
		# XXX we can't delete links, as there's no way to `touch` them.
		self.write('file.gup', BASH + 'exit 0')
		self.write('dir.gup', BASH + 'exit 0')
		self.write('link.gup', BASH + 'exit 0')
		self.touch('dir/contents')
		self.touch('file')
		os.symlink('link_dest', self.path('link'))
		self.assertEquals(self.listdir(), ['dir','dir.gup','file','file.gup', 'link', 'link.gup'])
		self.build('file', 'dir', 'link')
		self.assertEquals(self.listdir(), ['dir.gup','file.gup', 'link', 'link.gup'])

	def test_keeps_modified_file(self):
		self.write('file.gup', BASH + 'touch "$2"; exit 0')
		self.build('file')
		self.build('file')
		self.assertEquals(self.listdir(), ['file','file.gup'])

	def test_keeps_modified_dir(self):
		self.write('dir.gup', BASH + 'if [ -e "$2" ]; then touch "$2"; else mkdir "$2"; fi; exit 0')
		self.build('dir')
		self.build('dir')
		self.assertEquals(self.listdir(), ['dir', 'dir.gup'])

	def test_keeps_modified_link(self):
		self.touch('link_dest')
		self.write('link.gup', BASH + 'if [ -e "$2" ]; then touch "$2"; else ln -s link_dest "$2"; fi; exit 0')
		self.build('link')
		self.build('link')
		self.assertEquals(self.listdir(), ['link', 'link.gup', 'link_dest'])

	@unittest.skipIf(IS_WINDOWS, 'irrelevant on windows')
	def test_permissions_of_tempfile_are_maintained(self):
		self.write('hello.gup', BASH + 'echo -e "#!/bin/bash\necho ok" > "$1"; chmod a+x "$1"')
		self.build('hello')
		out = subprocess.check_output(self.path('hello'))
		self.assertEquals(out.strip().decode('ascii'), 'ok')
	
	def test_ignores_repeated_clobbers_on_update_build(self):
		self.touch('input')
		self.write('bad.gup', BASH + 'gup -u input; echo bad > "$2"')
		clobber_warning = '# WARNING bad.gup modified %s directly' % (os.path.join('.', 'bad'))

		def warning(lines):
			return next(iter(filter(lambda line: line.startswith('# WARN'), lines)), None)

		# initial build should have the warning
		lines = self.build_u('bad', include_logging=True)
		self.assertEquals(warning(lines), clobber_warning)

		# doesn't notify on rebuild
		lines = self.assertRebuilds('bad', lambda: self.touch('input'), built=True, include_logging=True)
		self.assertEquals(warning(lines), None)

		# does notify on explicit build
		lines = self.build('bad', include_logging=True)
		self.assertEquals(warning(lines), clobber_warning)


class TestSymlinkScripts(TestCase):
	def setUp(self):
		super(TestSymlinkScripts, self).setUp()
		if IS_WINDOWS:
			self.skipTest("symlinks")

	def test_creates_nonexisting_destinations_within_symlinks(self):
		self.mkdirp('dir')
		os.symlink('dir', self.path('a'))

		self.write("gup/a/b/c.gup", echo_to_target('$2'))
		self.build_assert('a/b/c', 'c')
	
	def test_rebuild_symlink_to_directory(self):
		self.mkdirp('dir')
		self.touch('dir/1')
		self.touch('dir/2')

		self.write('link.gup', BASH + 'ln -s dir "$1"')
		self.build('link')
		self.build('link')
		self.assertTrue(os.path.islink(self.path('link')))
		self.assertTrue(os.path.isdir(self.path('dir')))
	
	def test_cleans_up_symlink_to_directory_if_build_fails(self):
		self.write('link.gup', BASH + 'mkdir dir; touch dir/1 dir/2; ln -s "$(pwd)/dir" "$1"; exit 1')
		self.assertRaises(SafeError, lambda: self.build('link'))
		# should only remove _symlink_ - not actual contents
		self.assertTrue(os.path.exists(self.path('dir/1')))
		self.assertTrue(os.path.exists(self.path('dir/2')))

	def test_moves_broken_symlink_if_build_succeeds(self):
		self.write('link.gup', BASH + 'ln -s NOT_HERE "$1"')
		self.build('link')
		self.assertTrue(os.path.islink(self.path('link')))
		self.assertEquals(_tmp_output_files(self), [])

	def test_cleans_up_broken_symlink_if_build_fails(self):
		self.write('target.gup', BASH + 'ln -s NOT_HERE "$1"; exit 1')
		self.assertRaises(SafeError, lambda: self.build('target'))
		self.assertEquals(_tmp_output_files(self), [])

	def test_leaves_broken_symlink_at_dest_if_build_succeeds(self):
		self.write('link.gup', BASH + 'ln -s NOT_HERE "$2"')
		self.build('link')
		self.assertTrue(os.path.islink(self.path('link')))
		self.assertEquals(_tmp_output_files(self), [])

	def test_builder_is_invoked_via_link(self):
		self.write('buildscript.sh', echo_to_target('$(basename "$0")'))
		self.symlink('buildscript.sh', 'target.gup')
		self.build_assert('target', 'target.gup')
