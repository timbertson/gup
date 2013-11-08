from __future__ import print_function
import os
from os import path
import re
import itertools

from .log import getLogger
log = getLogger(__name__)

def _default_gup_files(filename):
	l = filename.split('.')
	for i in range(1,len(l)+1):
		ext = '.'.join(l[i:])
		if ext: ext = '.' + ext
		yield ("default%s.gup" % ext), ext

def _up_path(n):
	return '/'.join(itertools.repeat('..',n))

GUPFILE = 'Gupfile'

class Gupfile(object):
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

	def get_gupscript(self):
		path = self.guppath
		target_base = os.path.join(*self._base_parts(False))
		log.debug("target_base: %s" % (target_base,))

		if not self.indirect:
			return Gupscript(path, self.target, target_base)

		with open(path) as f:
			rules = parse_gupfile(f)
			log.debug("Parsed gupfile: %r" % rules)
	
		for script, ruleset in rules:
			if ruleset.match(self.target):
				base = os.path.join(target_base, os.path.dirname(script))
				return Gupscript(
					os.path.join(os.path.dirname(path), script),
					os.path.relpath(os.path.join(target_base, self.target), base),
					base)
		return None

class Gupscript(object):
	def __init__(self, path, target, basedir):
		self.path = path
		self.target = target
		self.basedir = basedir
		self.target_path = os.path.join(self.basedir, self.target)
		log.debug("Created %r" % (self,))
	
	def __repr__(self):
		return "Gupscript(path=%r, target=%r, basedir=%r)" % (self.path, self.target, self.basedir)

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
	dirparts = os.path.normpath(os.path.join(os.getcwd(), dirname)).split('/')
	dirdepth = len(dirparts)

	# find direct match for `{target}.gup` in all possible `/gup` dirs
	yield Gupfile(dirname, None, False, filename)
	for i in xrange(0, dirdepth):
		suff = '/'.join(dirparts[dirdepth - i:])
		base = path.join(dirname, _up_path(i))
		yield Gupfile(base, suff, False, filename)

	for up in xrange(0, dirdepth):
		# `up` controls how "fuzzy" the match is, in terms
		# of how specific the path is - least fuzzy wins.
		#
		# As `up` increments, we discard a folder on the base path.
		base_suff = '/'.join(dirparts[dirdepth - up:])
		parent_base = path.join(dirname, _up_path(up))
		target_id = os.path.join(base_suff, filename)
		yield Gupfile(parent_base, None, True, target_id)
		for i in xrange(0, dirdepth - up):
			# `i` is how far up the directory tree we're looking for the gup/ directory
			suff = '/'.join(dirparts[dirdepth - i - up:dirdepth - up])
			base = path.join(parent_base, _up_path(i))
			yield Gupfile(base, suff, True, target_id)

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
	
	def __repr__(self):
		return repr(self.includes + self.excludes)

def parse_gupfile(f):
	r'''
	>>> parse_gupfile([
	...   "foo.gup:",
	...   " foo1",
	...   "# comment",
	...   "",
	...   "\t foo2 # comment",
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
	for line in f:
		line = re.sub('#.*', '', line)
		new_rule = not re.match('^\s', line)
		line = line.strip()
		if not line: continue
		if new_rule:
			if current_matches:
				rules.append([current_gupfile, current_matches])
			current_matches = []
			assert line.endswith(':')
			line = line[:-1]
			current_gupfile = line.strip()
		else:
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
		log.debug("Compiled %r -> %r" % (self.text, regexp.pattern))
		def match(f):
			log.debug("Matching %r against %r" % (f, regexp.pattern))
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
