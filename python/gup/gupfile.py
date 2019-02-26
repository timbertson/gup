from __future__ import print_function
import os
from os import path
import re
import itertools

from .whichcraft import which
from .log import getLogger
from .error import SafeError
from .var import INDENT, PY3
_log = getLogger(__name__)

if PY3:
	xrange = range

def _default_gup_files(filename):
	l = filename.split('.')
	for i in range(1,len(l)+1):
		ext = '.'.join(l[i:])
		if ext: ext = '.' + ext
		yield ("default%s.gup" % ext), ext

def _up_path(n):
	return os.path.sep.join(itertools.repeat('..',n))

GUPFILE = 'Gupfile'

class BuildCandidate(object):
	'''
	A potential builder for a given target.

	This could be a target.gup file or a Gupfile.
	It may not exist, and if it does exist
	it may not contain a definition for the given target.

	get_builder() returns the actual Builder, if there is one
	'''

	def __init__(self, root, suffix, indirect, target):
		self.root = os.path.normpath(root)
		self.suffix = suffix
		self.gupfile = GUPFILE if indirect else target + '.gup'
		self.target = target
		self.indirect = indirect
	
	@property
	def guppath(self):
		return os.path.join(*(self._base_parts(True) + [self.gupfile]))
	
	def __repr__(self):
		parts = ['[gup]' if part == 'gup' else part for part in self._base_parts(True)]
		parts.append(self.gupfile)
		return "%s (%s)" % (os.path.join(*parts), self.target)

	def _base_parts(self, include_gup):
		parts = [self.root]
		if self.suffix is not None:
			if include_gup:
				parts.append('gup')
			if self.suffix is not True:
				parts.append(self.suffix)
		return parts

	def get_builder(self):
		path = self.guppath
		if not os.path.exists(path):
			return None
		if os.path.isdir(path):
			_log.trace("skipping directory: %s", path)
			return None

		_log.trace("candidate exists: %s" % (path,))

		def target_is_builder():
			target_name = os.path.basename(self.target)
			return target_name == GUPFILE or os.path.splitext(target_name)[1].lower() == '.gup'
		
		build_basedir = os.path.join(*self._base_parts(False))
		_log.trace("build_basedir: %s" % (build_basedir,))

		if not self.indirect:
			if target_is_builder():
				_log.debug("ignoring direct builder for target %s", path)
				# gupfiles & scripts can only be built by Gupfile targets, not .gup scripts
				return None
			return Builder(path, self.target, build_basedir, parent=None)

		with open(path) as f:
			try:
				rules = parse_gupfile(f)
			except AssertionError as e:
				reason = " (%s)" % (e.message,) if e.message else ""
				raise SafeError("Invalid %s: %s%s" % (GUPFILE, path, reason))
			_log.trace("Parsed gupfile: %r" % rules)
	
		match_target = self.target
		# always use `/` as path sep in gupfile patterns
		if os.path.sep != '/':
			match_target = self.target.replace(os.path.sep, '/')

		def find_matching_rule(matchfn, target, match_target):
			for script, ruleset in rules:
				if matchfn(ruleset, match_target):
					base = os.path.realpath(build_basedir)
					parent = None

					if script.startswith('!'):
						script = script[1:]
						script_path = which(script)
						if script_path is None:
							raise SafeError("Build command not found on PATH: %s\n     %s(specified in %s)" % (script, INDENT, path))
					else:
						script_path = os.path.join(os.path.dirname(path), script)
						parent = find_matching_rule(Guprules.match_exactly, script, script)
						script = os.path.normpath(script)
					return Builder(
						script_path,
						os.path.relpath(os.path.join(build_basedir, target), base),
						base, parent)
			return None

		match_fn = Guprules.match_exactly if target_is_builder() else Guprules.match
		return find_matching_rule(match_fn, self.target, match_target)

class Builder(object):
	'''
	The canonical builder for a target.
	`path` is the path to the build script, even if this
	builder was obtained indirectly (via a Gupfile match)
	'''
	def __init__(self, script_path, target, basedir, parent):
		self.path = script_path
		self.realpath = os.path.realpath(self.path)
		self.target = target
		self.basedir = basedir
		self.target_path = os.path.join(self.basedir, self.target)
		self.parent = parent
	
	def __repr__(self):
		return "Builder(path=%r, target=%r, basedir=%r, parent=%r)" % (self.path, self.target, self.basedir, self.parent)

	@staticmethod
	def for_target(path):
		for candidate in possible_gup_files(path):
			builder = candidate.get_builder()
			if builder is not None:
				return builder
		return None

def possible_gup_files(p):
	r'''
	Finds all direct gup files for a target.

	Each entry yields:
		gupdir:	  folder containing .gup file
		gupfile:   filename of .gup file

	>>> for g in possible_gup_files('/a/b/c/d/e'): print(g)
	/a/b/c/d/e.gup (e)
	/a/b/c/d/[gup]/e.gup (e)
	/a/b/c/[gup]/d/e.gup (e)
	/a/b/[gup]/c/d/e.gup (e)
	/a/[gup]/b/c/d/e.gup (e)
	/[gup]/a/b/c/d/e.gup (e)
	/a/b/c/d/Gupfile (e)
	/a/b/c/d/[gup]/Gupfile (e)
	/a/b/c/[gup]/d/Gupfile (e)
	/a/b/[gup]/c/d/Gupfile (e)
	/a/[gup]/b/c/d/Gupfile (e)
	/[gup]/a/b/c/d/Gupfile (e)
	/a/b/c/Gupfile (d/e)
	/a/b/c/[gup]/Gupfile (d/e)
	/a/b/[gup]/c/Gupfile (d/e)
	/a/[gup]/b/c/Gupfile (d/e)
	/[gup]/a/b/c/Gupfile (d/e)
	/a/b/Gupfile (c/d/e)
	/a/b/[gup]/Gupfile (c/d/e)
	/a/[gup]/b/Gupfile (c/d/e)
	/[gup]/a/b/Gupfile (c/d/e)
	/a/Gupfile (b/c/d/e)
	/a/[gup]/Gupfile (b/c/d/e)
	/[gup]/a/Gupfile (b/c/d/e)
	/Gupfile (a/b/c/d/e)
	/[gup]/Gupfile (a/b/c/d/e)

	>>> for g in itertools.islice(possible_gup_files('x/y/somefile'), 0, 3): print(g)
	x/y/somefile.gup (somefile)
	x/y/[gup]/somefile.gup (somefile)
	x/[gup]/y/somefile.gup (somefile)

	>>> for g in itertools.islice(possible_gup_files('/x/y/somefile'), 0, 3): print(g)
	/x/y/somefile.gup (somefile)
	/x/y/[gup]/somefile.gup (somefile)
	/x/[gup]/y/somefile.gup (somefile)
	'''
	# we need an absolute path to tell how far up the tree we should go
	dirname,filename = os.path.split(p)
	dirparts = os.path.normpath(os.path.join(os.getcwd(), dirname)).split(os.path.sep)
	dirdepth = len(dirparts)

	# find direct match for `{target}.gup` in all possible `/gup` dirs
	yield BuildCandidate(dirname, None, False, filename)
	for i in xrange(0, dirdepth):
		suff = os.path.sep.join(dirparts[dirdepth - i:])
		base = path.join(dirname, _up_path(i))
		yield BuildCandidate(base, suff, False, filename)

	for up in xrange(0, dirdepth):
		# `up` controls how "fuzzy" the match is, in terms
		# of how specific the path is - least fuzzy wins.
		#
		# As `up` increments, we discard a folder on the base path.
		base_suff = os.path.sep.join(dirparts[dirdepth - up:])
		parent_base = path.join(dirname, _up_path(up))
		target_id = os.path.join(base_suff, filename)
		yield BuildCandidate(parent_base, None, True, target_id)
		for i in xrange(0, dirdepth - up):
			# `i` is how far up the directory tree we're looking for the gup/ directory
			suff = os.path.sep.join(dirparts[dirdepth - i - up:dirdepth - up])
			base = path.join(parent_base, _up_path(i))
			yield BuildCandidate(base, suff, True, target_id)

class Guprules(object):
	def __init__(self, rules):
		self.includes = []
		self.excludes = []
		for r in rules:
			(self.excludes if r.invert else self.includes).append(r)
	
	def match(self, p):
		return (
			any((rule.match(p) for rule in self.includes))
				and not
			any((rule.match(p) for rule in self.excludes))
		)

	def match_exactly(self, p):
		return (
			any((rule.match_exactly(p) for rule in self.includes))
		)
	
	def __repr__(self):
		return repr(self.includes + self.excludes)

def parse_gupfile(f):
	r'''
	>>> parse_gupfile([
	...   "foo.gup:",
	...   " foo1",
	...   "# comment",
	...   "",
	...   "\t foo2",
	...   "# comment",
	...   "ignoreme:",
	...   "bar.gup :",
	...   " bar1\t ",
	...   "    bar2",
	... ])
	[('foo.gup', [MatchRule('foo1'), MatchRule('foo2')]), ('bar.gup', [MatchRule('bar1'), MatchRule('bar2')])]
	'''
	rules = []
	current_gupfile = None
	current_matches = None
	lineno = 1
	for line in f:
		lineno += 1
		if line.startswith('#'): continue
		new_rule = not re.match('^\s', line)
		line = line.strip()
		if not line: continue
		if new_rule:
			if current_matches:
				rules.append([current_gupfile, current_matches])
			current_matches = []
			assert line.endswith(':'), "line %s" % lineno
			line = line[:-1]
			current_gupfile = line.strip()
		else:
			assert current_matches is not None, "line %s" % lineno
			current_matches.append(MatchRule(line))

	if current_matches:
		rules.append([current_gupfile, current_matches])
	return [(gupfile, Guprules(guprules)) for gupfile, guprules in rules]

class MatchRule(object):
	_splitter = re.compile(r'(\*+)')
	def __init__(self, text):
		self._match = None
		self.invert = text.startswith('!')
		if self.invert:
			text = text[1:]
		self.text = text

	def __call__(self, f):
		return self.match(f)

	def match_exactly(self, f):
		return self.text == f

	def match(self, f):
		regexp = '^'
		for i, part in enumerate(re.split(self._splitter, self.text)):
			if i % 2 == 0:
				# raw part
				regexp += re.escape(part)
			else:
				if part == '*':
					regexp += "([^/]*)"
				elif part == '**':
					regexp += "(.*)"
				else:
					raise ValueError("Invalid pattern: %s" % (self.text))
		regexp += '$'
		regexp = re.compile(regexp)
		_log.trace("Compiled %r -> %r" % (self.text, regexp.pattern))
		def match(f):
			_log.trace("Matching %r against %r" % (f, regexp.pattern))
			return bool(regexp.match(f))
		self.match = match
		return self.match(f)

	def __repr__(self):
		text = self.text
		if self.invert:
			text = '!' + text
		return 'MatchRule(%r)' % (text,)


if __name__ == '__main__':
	import doctest
	doctest.testmod()
