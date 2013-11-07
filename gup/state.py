import os
import logging
import contextlib
import errno

from .util import *
from .log import getLogger
log = getLogger(__name__)

class TargetState(object):
	def __init__(self, p):
		self.path = p
	
	def meta_path(self, ext):
		base, target = os.path.split(self.path)
		meta_dir = os.path.join(base, '.gup')
		return os.path.join(meta_dir, "%s.%s" % (target, ext))

	def _ensure_meta_path(self, ext):
		p = self.meta_path(ext)
		mkdirp(os.path.dirname(p))
		return p
	
	def deps(self):
		try:
			f = open(self.meta_path('deps'))
		except IOError as e:
			if e.errno != errno.ENOENT: raise
			return None
		else:
			with f:
				return Dependencies(self.path, f)

	def add_dependency(self, dep):
		log.debug('add dep: %s -> %s' % (self.path, dep))
		with open(self.meta_path('deps_next'), 'a') as f:
			dep.append_to(f)
	
	@contextlib.contextmanager
	def perform_build(self):
		temp = self._ensure_meta_path('deps_next')
		with open(temp, 'w') as f:
			Dependencies.init_file(f)
		try:
			yield
		except:
			os.remove(temp)
			raise
		else:
			os.rename(temp, self.meta_path('deps'))

class Dependencies(object):
	FORMAT_VERSION = 1
	def __init__(self, path, file):
		self.path = path
		self.rules = []
		if file is None:
			self.rules.append(NeverBuilt())
		else:
			version_line = file.readline().strip()
			log.debug("version_line: %s" % (version_line,))
			if not version_line.startswith('version:'): raise ValueError("Invalid file")
			_, file_version = version_line.split(' ')
			if int(file_version) != self.FORMAT_VERSION:
				raise ValueError("version mismatch: can't read format version %s" % (file_version,))

			for line in file:
				self.rules.append(Dependency.parse(line.rstrip()))
	
	def is_dirty(self):
		if not os.path.exists(self.path):
			log.debug("target does not exist - assumed dirty")
			return True
		base = os.path.dirname(self.path)
		return any(r.is_dirty(base) for r in self.rules) or any(r.is_dependency_dirty(base) for r in self.rules)
	
	@classmethod
	def init_file(cls, f):
		f.write('version: %s\n' % (cls.FORMAT_VERSION,))
	
	def __repr__(self):
		return 'Dependencies<%r>' % (self.rules,)

class Dependency(object):
	@staticmethod
	def parse(line):
		for candidate in [FileDependency]:
			if line.startswith(candidate.tag):
				cls = candidate
				break
		else:
			raise ValueError("unknown dependency line: %s" % (line,))
		fields = line.split(' ', cls.num_fields)[1:]
		return cls.parse(*fields)

	def append_to(self, file):
		line = ' '.join(self.fields)
		assert "\n" not in line
		file.write(line + "\n")
	
	def is_dependency_dirty(self, base): return False

class NeverBuilt(object):
	def is_dirty(self, base): return True

	def append_to(self, file): pass
	def __repr__(self): return 'NeverBuilt()'

class FileDependency(Dependency):
	num_fields = 2
	tag = 'filedep:'

	def __init__(self, mtime, path):
		self.path = path
		self.mtime = mtime
	
	@classmethod
	def parse(cls, mtime, path):
		return cls(int(mtime) or None, path)
	
	@property
	def fields(self):
		return ['filedep:', str(self.mtime or 0), self.path]

	def is_dirty(self, base):
		current_mtime = get_mtime(os.path.join(base, self.path))
		if current_mtime != self.mtime:
			log.debug("Dirty: %s (stored mtime is %r, current is %r)" % (self.path,self.mtime, current_mtime))
			return True
		return False
	
	def is_dependency_dirty(self, base):
		state = TargetState(os.path.join(base, self.path))
		deps = state.deps()
		if deps is None:
			return False # not a buildable target
		return deps.is_dirty()
	
	def __repr__(self):
		return 'FileDependency(%r, %r)' % (self.mtime, self.path)

