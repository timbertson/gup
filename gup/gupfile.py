from __future__ import print_function
import os
from os import path
import re
import itertools
import logging
log = logging.getLogger(__name__)

def _default_gup_files(filename):
	l = filename.split('.')
	for i in range(1,len(l)+1):
		ext = '.'.join(l[i:])
		if ext: ext = '.' + ext
		yield ("default%s.gup" % ext), ext

def _up_path(n):
	return '/'.join(itertools.repeat('..',n))

def possible_gup_files(p):
	r'''
	Finds all direct gup files for a target.

	Each entry yields:
		gupdir:	  folder containing .gup file
		gupfile:   filename of .gup file

	>>> for (base, gupfile) in possible_gup_files('/a/b/c/d/e.ext'):
	...		print(os.path.join(base, gupfile))
	/a/b/c/d/e.ext.gup
	/a/b/c/d/gup/e.ext.gup
	/a/b/c/d/../gup/d/e.ext.gup
	/a/b/c/d/../../gup/c/d/e.ext.gup
	/a/b/c/d/../../../gup/b/c/d/e.ext.gup
	/a/b/c/d/../../../../gup/a/b/c/d/e.ext.gup
	/a/b/c/d/Gupfile
	/a/b/c/d/gup/Gupfile
	/a/b/c/d/../gup/d/Gupfile
	/a/b/c/d/../../gup/c/d/Gupfile
	/a/b/c/d/../../../gup/b/c/d/Gupfile
	/a/b/c/d/../../../../gup/a/b/c/d/Gupfile
	/a/b/c/d/../Gupfile
	/a/b/c/d/../gup/Gupfile
	/a/b/c/d/../../gup/c/Gupfile
	/a/b/c/d/../../../gup/b/c/Gupfile
	/a/b/c/d/../../../../gup/a/b/c/Gupfile
	/a/b/c/d/../../Gupfile
	/a/b/c/d/../../gup/Gupfile
	/a/b/c/d/../../../gup/b/Gupfile
	/a/b/c/d/../../../../gup/a/b/Gupfile
	/a/b/c/d/../../../Gupfile
	/a/b/c/d/../../../gup/Gupfile
	/a/b/c/d/../../../../gup/a/Gupfile
	/a/b/c/d/../../../../Gupfile
	/a/b/c/d/../../../../gup/Gupfile

	>>> for (base, gupfile) in itertools.islice(possible_gup_files('x/y/somefile'), 0, 3):
	...		print(os.path.join(base, gupfile))
	x/y/somefile.gup
	x/y/gup/somefile.gup
	x/y/../gup/y/somefile.gup

	>>> for (base, gupfile) in itertools.islice(possible_gup_files('/x/y/somefile'), 0, 3):
	...		print(os.path.join(base, gupfile))
	/x/y/somefile.gup
	/x/y/gup/somefile.gup
	/x/y/../gup/y/somefile.gup
	'''
	# we need an absolute path to tell how far up the tree we should go
	dirname,filename = os.path.split(p)
	dirparts = os.path.normpath(os.path.join(os.getcwd(), dirname)).split('/')
	dirdepth = len(dirparts)
	gupfilename = filename + '.gup'

	# find direct match for `{target}.gup` in all possible `/gup` dirs
	yield (dirname, gupfilename)
	for i in xrange(0, dirdepth):
		suff = '/'.join(dirparts[dirdepth - i:])
		base = path.join(dirname, _up_path(i))
		yield (path.join(base, 'gup', suff), gupfilename)

	for up in xrange(0, dirdepth):
		# `up` controls how "fuzzy" the match is, in terms
		# of how specific the path is - least fuzzy wins.
		#
		# As `up` increments, we discard a folder on the base path.
		base_suff = '/'.join(dirparts[dirdepth - up:])
		parent_base = path.join(dirname, _up_path(up))
		yield (parent_base, GUPFILE)
		for i in xrange(0, dirdepth - up):
			# `i` is how far up the directory tree we're looking for the gup/ directory
			suff = '/'.join(dirparts[dirdepth - i - up:dirdepth - up])
			base = path.join(parent_base, _up_path(i))
			yield (path.join(base, 'gup', suff), GUPFILE)

GUPFILE = 'Gupfile'

class Gupfile(object):
	def __init__(self, p):
		self.path = p
		#XXX lock file
		with open(p) as f:
			self.rules = parse_gupfile(f)
			log.debug("Parsed gupfile: %r" % self.rules)
	
	def builder(self, p):
		for gupfile, rules in self.rules:
			if rules.match(p):
				return gupfile
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
