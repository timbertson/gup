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

class PossibleGupFile(object):
	def __init__(self, gupdir, gupfile, target):
		self.gupdir = os.path.normpath(gupdir)
		self.gupfile = gupfile
		self.target = target
	
	@property
	def guppath(self):
		return os.path.join(self.gupdir, self.gupfile)

	@property
	def indirect(self):
		return self.gupfile == GUPFILE

def possible_gup_files(p):
	r'''
	Finds all direct gup files for a target.

	Each entry yields:
		gupdir:	  folder containing .gup file
		gupfile:   filename of .gup file

	>>> def p(g):
	...   print(' | '.join([os.path.join(g.gupdir, g.gupfile), g.target]))
	>>> for g in possible_gup_files('/a/b/c/d/e'): p(g)
	/a/b/c/d/e.gup | e
	/a/b/c/d/gup/e.gup | e
	/a/b/c/gup/d/e.gup | e
	/a/b/gup/c/d/e.gup | e
	/a/gup/b/c/d/e.gup | e
	/gup/a/b/c/d/e.gup | e
	/a/b/c/d/Gupfile | e
	/a/b/c/d/gup/Gupfile | e
	/a/b/c/gup/d/Gupfile | e
	/a/b/gup/c/d/Gupfile | e
	/a/gup/b/c/d/Gupfile | e
	/gup/a/b/c/d/Gupfile | e
	/a/b/c/Gupfile | d/e
	/a/b/c/gup/Gupfile | d/e
	/a/b/gup/c/Gupfile | d/e
	/a/gup/b/c/Gupfile | d/e
	/gup/a/b/c/Gupfile | d/e
	/a/b/Gupfile | c/d/e
	/a/b/gup/Gupfile | c/d/e
	/a/gup/b/Gupfile | c/d/e
	/gup/a/b/Gupfile | c/d/e
	/a/Gupfile | b/c/d/e
	/a/gup/Gupfile | b/c/d/e
	/gup/a/Gupfile | b/c/d/e
	/Gupfile | a/b/c/d/e
	/gup/Gupfile | a/b/c/d/e

	>>> for g in itertools.islice(possible_gup_files('x/y/somefile'), 0, 3):
	...		print(os.path.join(g.gupdir, g.gupfile))
	x/y/somefile.gup
	x/y/gup/somefile.gup
	x/gup/y/somefile.gup

	>>> for g in itertools.islice(possible_gup_files('/x/y/somefile'), 0, 3):
	...		print(os.path.join(g.gupdir, g.gupfile))
	/x/y/somefile.gup
	/x/y/gup/somefile.gup
	/x/gup/y/somefile.gup
	'''
	# we need an absolute path to tell how far up the tree we should go
	dirname,filename = os.path.split(p)
	dirparts = os.path.normpath(os.path.join(os.getcwd(), dirname)).split('/')
	dirdepth = len(dirparts)
	gupfilename = filename + '.gup'

	# find direct match for `{target}.gup` in all possible `/gup` dirs
	yield PossibleGupFile(dirname, gupfilename, filename)
	for i in xrange(0, dirdepth):
		suff = '/'.join(dirparts[dirdepth - i:])
		base = path.join(dirname, _up_path(i))
		yield PossibleGupFile(path.join(base, 'gup', suff), gupfilename, filename)

	for up in xrange(0, dirdepth):
		# `up` controls how "fuzzy" the match is, in terms
		# of how specific the path is - least fuzzy wins.
		#
		# As `up` increments, we discard a folder on the base path.
		base_suff = '/'.join(dirparts[dirdepth - up:])
		parent_base = path.join(dirname, _up_path(up))
		target_id = os.path.join(base_suff, filename)
		yield PossibleGupFile(parent_base, GUPFILE, target_id)
		for i in xrange(0, dirdepth - up):
			# `i` is how far up the directory tree we're looking for the gup/ directory
			suff = '/'.join(dirparts[dirdepth - i - up:dirdepth - up])
			base = path.join(parent_base, _up_path(i))
			yield PossibleGupFile(path.join(base, 'gup', suff), GUPFILE, target_id)

GUPFILE = 'Gupfile'

class Gupfile(object):
	def __init__(self, p):
		self.path = p
		#XXX lock file
		with open(p) as f:
			self.rules = parse_gupfile(f)
			log.debug("Parsed gupfile: %r" % self.rules)
	
	def builder(self, target):
		for script, rules in self.rules:
			if rules.match(target):
				return os.path.join(os.path.dirname(self.path), script)
		return None

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
