#!/usr/bin/env python
from __future__ import print_function
import os, sys, re
import stat
import subprocess

# A somewhat-hacky script to process gup/*.py modules
# and merge them into a single file.
#
# Restrictions:
#
# 1) All gup-module imports must take the form:
#        from .MOD import sym1, sym2, ...
#    At join time, these lines are stripped out and
#    `sym1` `sym2` will simply be globals in the generated
#    script.
#
# 2) No two modules may have the same globals
#    (as a side effect of #1).
#    Private module-globals (anything beginning with _)
#    are OK, they will be mangled from _var -> _MOD_var
#
# 3) Modules must be listed in dependency-order
#    (if they anything from other modules at the top-level)
#
# 3) If anything else goes wrong, hopefully pychecker
#    or the automated tests will pick it up.

def main():
	root, output_path = sys.argv[1:]
	assert output_path.endswith('.py')
	root = root.rstrip('/')

	here = os.path.dirname(os.path.abspath(__file__))

	def is_interesting(filename):
		return filename.endswith('.py') and not filename == '__init__.py'

	existing_files = set(filter(is_interesting, os.listdir(root)))
	
	files = [mod + '.py' for mod in 'var log version error util parallel gupfile state builder task cmd'.split()]
	assert set(files) == existing_files, "file mismatch:\n%r\n%r" % (sorted(files), sorted(existing_files))

	mods = []

	with open(output_path, 'w') as output:
		with open(os.path.join(here, 'header.py')) as header:
			lines = header.read().splitlines()
			with open(os.path.join(here, '../../VERSION')) as ver:
				lines.insert(2, '# VERSION: %s' % ver.read().strip())
			output.write('\n'.join(lines))

		main_section = None
		for filename in files:
			if not filename.endswith('.py'):
				continue
			if filename == '__init__.py':
				continue
			print("\nAdding %s" % (filename,))
			path = os.path.join(root, filename)
			mod = filename[:-3]
			mods.append(mod)

			in_main = False
			with open(path) as f:
				output.write('\n## --- %s --- ##\n' % (filename,))

				lines = f.readlines()

				module_locals = {}
				for line in lines:
					match = re.match('^(_[^_][^ ]*) *=', line)
					match = match or re.match('^def (_[^_][^ (]*)', line)
					if match:
						var = match.group(1)
						if var in module_locals:
							continue
						else:
							replacement ="_%s%s" % (mod, var)
							print("scoping %s -> %s" % (var, replacement))
							module_locals[var] = replacement

				def replace_locals(line):
					for var, repl in module_locals.items():
						line = re.sub(r'(^|\b)%s($|\b)' % (re.escape(var),), repl, line)
					return line
				lines = list(map(replace_locals, lines))

				for line in lines:
					line = line.rstrip()
					if line.startswith('#'): continue
					if line == 'from __future__ import print_function': continue
					if line.startswith('__all__'): continue

					if re.match('^\s*from \.', line):
						# print("  Skipping import: %s" % (line,))
						assert 'from . ' not in line, "Bad import line: %s" % (line,)
						continue

					if in_main:
						if mod == 'cmd':
							main_section.append(line)
						continue

					in_main = re.match('if __name__', line)
					if in_main:
						if mod == 'cmd':
							main_section = []
							main_section.append(line)
						continue

					# fix getLogger calls to not use __main__
					line = re.sub('(.*getLogger\()__name__', r"\1'gup.%s'" % (mod,), line)
					output.write(line + '\n')

		assert main_section, "No main section found!"
		output.write('\n'.join(main_section))

	st = os.stat(output_path)
	os.chmod(output_path, st.st_mode | 0111)

	env = os.environ.copy()
	def check(mods, basedir):
		if env.get('SKIP_PYCHECKER', '0').strip() == '1':
			print("WARN: Skipping pychecker check ...", file=sys.stderr)
			return
		env['PYTHONPATH'] = basedir
		args = ['pychecker', '--limit', '100', '--no-reimport', '--no-miximport', '--no-argsused', '--no-shadowbuiltin', '--no-classattr', '--no-returnvalues'] + mods
		print("Running: %r %r" % (args, env['PYTHONPATH']))
		try:
			subprocess.check_call(args, env=env, cwd=basedir)
		except OSError as e:
			print("\nERROR: Failed to run pychecker - is it installed?\nExport SKIP_PYCHECKER=1 to skip this check", file=sys.stderr)
			sys.exit(1)

	print('\n\n# PYCHECKER')
	print('#----- ORIGINAL ------#')
	check(['gup.' + mod for mod in mods], os.path.dirname(here))

	print('#----- BUILT ------#')
	output_mod = os.path.basename(output_path)[:-3]
	check([output_mod], os.path.dirname(os.path.abspath(output_path)))

	print("\n\nOK!")

if __name__ == '__main__':
	main()
