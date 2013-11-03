from __future__ import print_function
import os
from os import path
import re
import itertools
import logging
log = logging.getLogger(__name__)

def _default_do_files(filename):
	l = filename.split('.')
	for i in range(1,len(l)+1):
		ext = '.'.join(l[i:])
		if ext: ext = '.' + ext
		yield ("default%s.do" % ext), ext

def _up_path(n):
	return '/'.join(itertools.repeat('..',n))

def possible_do_files(p):
	r'''
	Finds all direct do files for a target.

	Each entry yields:
		dodir:	  folder containing .do file
		dofile:   filename of .do file

	>>> for (base, dofile) in possible_do_files('/a/b/c/d/e.ext'):
	...		print(os.path.join(base, dofile))
	/a/b/c/d/e.ext.do
	/a/b/c/d/do/e.ext.do
	/a/b/c/d/../do/d/e.ext.do
	/a/b/c/d/../../do/c/d/e.ext.do
	/a/b/c/d/../../../do/b/c/d/e.ext.do
	/a/b/c/d/../../../../do/a/b/c/d/e.ext.do
	/a/b/c/d/Dofile
	/a/b/c/d/do/Dofile
	/a/b/c/d/../do/d/Dofile
	/a/b/c/d/../../do/c/d/Dofile
	/a/b/c/d/../../../do/b/c/d/Dofile
	/a/b/c/d/../../../../do/a/b/c/d/Dofile
	/a/b/c/d/../Dofile
	/a/b/c/d/../do/Dofile
	/a/b/c/d/../../do/c/Dofile
	/a/b/c/d/../../../do/b/c/Dofile
	/a/b/c/d/../../../../do/a/b/c/Dofile
	/a/b/c/d/../../Dofile
	/a/b/c/d/../../do/Dofile
	/a/b/c/d/../../../do/b/Dofile
	/a/b/c/d/../../../../do/a/b/Dofile
	/a/b/c/d/../../../Dofile
	/a/b/c/d/../../../do/Dofile
	/a/b/c/d/../../../../do/a/Dofile
	/a/b/c/d/../../../../Dofile
	/a/b/c/d/../../../../do/Dofile

	>>> for (base, dofile) in itertools.islice(possible_do_files('x/y/somefile'), 0, 3):
	...		print(os.path.join(base, dofile))
	x/y/somefile.do
	x/y/do/somefile.do
	x/y/../do/y/somefile.do

	>>> for (base, dofile) in itertools.islice(possible_do_files('/x/y/somefile'), 0, 3):
	...		print(os.path.join(base, dofile))
	/x/y/somefile.do
	/x/y/do/somefile.do
	/x/y/../do/y/somefile.do
	'''
	# we need an absolute path to tell how far up the tree we should go
	dirname,filename = os.path.split(p)
	dirparts = os.path.normpath(os.path.join(os.getcwd(), dirname)).split('/')
	dirdepth = len(dirparts)
	dofilename = filename + '.do'

	# find direct match for `{target}.do` in all possible `/do` dirs
	yield (dirname, dofilename)
	for i in xrange(0, dirdepth):
		suff = '/'.join(dirparts[dirdepth - i:])
		base = path.join(dirname, _up_path(i))
		yield (path.join(base, 'do', suff), dofilename)

	for up in xrange(0, dirdepth):
		# `up` controls how "fuzzy" the match is, in terms
		# of how specific the path is - least fuzzy wins.
		#
		# As `up` increments, we discard a folder on the base path.
		base_suff = '/'.join(dirparts[dirdepth - up:])
		parent_base = path.join(dirname, _up_path(up))
		yield (parent_base, DOFILE)
		for i in xrange(0, dirdepth - up):
			# `i` is how far up the directory tree we're looking for the do/ directory
			suff = '/'.join(dirparts[dirdepth - i - up:dirdepth - up])
			base = path.join(parent_base, _up_path(i))
			yield (path.join(base, 'do', suff), DOFILE)

DOFILE = 'Dofile'

class Dofile(object):
	def __init__(self, p):
		self.path = p
		#XXX lock file
		with open(p) as f:
			self.rules = parse_dofile(f)
			log.debug("Parsed dofile: %r" % self.rules)
	
	def builder(self, p):
		for dofile, rules in self.rules:
			if rules.match(p):
				return dofile
		return None

class Dorules(object):
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

def parse_dofile(f):
	r'''
	>>> parse_dofile([
	...   "foo.do:",
	...   " foo1",
	...   "# comment",
	...   "",
	...   "\t foo2 # comment",
	...   "ignoreme:",
	...   "bar.do :",
	...   " bar1\t ",
	...   "    bar2",
	... ])
	[['foo.do', [MatchRule('foo1'), MatchRule('foo2')]], ['bar.do', [MatchRule('bar1'), MatchRule('bar2')]]]
	'''
	rules = []
	current_dofile = None
	current_matches = None
	for line in f:
		line = re.sub('#.*', '', line)
		new_rule = not re.match('^\s', line)
		line = line.strip()
		if not line: continue
		if new_rule:
			if current_matches:
				rules.append([current_dofile, current_matches])
			current_matches = []
			assert line.endswith(':')
			line = line[:-1]
			current_dofile = line.strip()
		else:
			current_matches.append(MatchRule(line))

	if current_matches:
		rules.append([current_dofile, current_matches])
	return [(dofile, Dorules(dorules)) for dofile, dorules in rules]

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
