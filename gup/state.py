import os
import logging
import contextlib
import errno

from .util import *
from .log import getLogger
from .gupfile import Gupscript
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
	def perform_build(self, gupscript):
		assert os.path.exists(gupscript)
		gupfile_dep = GupfileDependency(
			path=os.path.relpath(gupscript, os.path.dirname(self.path)),
			mtime=get_mtime(gupscript))
		log.debug("created dep %s from gupfile %r" % (gupfile_dep, gupscript))
		temp = self._ensure_meta_path('deps_next')
		with open(temp, 'w') as f:
			Dependencies.init_file(f)
			gupfile_dep.append_to(f)
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

			while True:
				line = file.readline()
				if not line: break
				self.rules.append(Dependency.parse(line.rstrip()))
	
	def is_dirty(self, gupscript):
		if not os.path.exists(self.path):
			log.debug("target does not exist - assumed dirty")
			return True
		base = os.path.dirname(self.path)
		gupscript = os.path.relpath(gupscript, base)

		return (
			any(r.is_dirty(base, gupscript) for r in self.rules) or
			any(r.is_dependency_dirty(base) for r in self.rules))
	
	@classmethod
	def init_file(cls, f):
		f.write('version: %s\n' % (cls.FORMAT_VERSION,))
	
	def __repr__(self):
		return 'Dependencies<%r>' % (self.rules,)

class Dependency(object):
	@staticmethod
	def parse(line):
		log.debug("parsing line: %s" % (line,))
		for candidate in [FileDependency, GupfileDependency, AlwaysRebuild]:
			if line.startswith(candidate.tag):
				cls = candidate
				break
		else:
			raise ValueError("unknown dependency line: %r" % (line,))
		fields = line.split(' ', cls.num_fields)[1:]
		return getattr(cls, 'deserialize', cls)(*fields)

	def append_to(self, file):
		line = self.tag + ' ' + ' '.join(self.fields)
		assert "\n" not in line
		file.write(line + "\n")
	
	def is_dependency_dirty(self, base): return False
	def __repr__(self):
		return '%s(%s)' % (type(self).__name__, ', '.join(map(repr, self.fields)))

class NeverBuilt(object):
	fields = []
	def is_dirty(self, base, gupscript):
		log.debug('DIRTY: never built')
		return True
	def append_to(self, file): pass

class AlwaysRebuild(Dependency):
	tag = 'always:'
	num_fields = 0
	fields = []
	def is_dirty(self, base, gupscript):
		log.debug('DIRTY: always rebuild')
		return True

class FileDependency(Dependency):
	num_fields = 2
	tag = 'filedep:'

	def __init__(self, mtime, path):
		self.path = path
		self.mtime = mtime
	
	@classmethod
	def deserialize(cls, mtime, path):
		return cls(int(mtime) or None, path)
	
	@property
	def fields(self):
		return [str(self.mtime or 0), self.path]

	def is_dirty(self, base, gupscript):
		current_mtime = get_mtime(os.path.join(base, self.path))
		# log.debug("Compare mtime %s to %s" % (current_mtime, self.mtime))
		if current_mtime != self.mtime:
			log.debug("DIRTY: %s (stored mtime is %r, current is %r)" % (self.path,self.mtime, current_mtime))
			return True
		return False
	
	def is_dependency_dirty(self, base):
		target_path = os.path.join(base, self.path)
		state = TargetState(target_path)
		gupscript = Gupscript.for_target(target_path)
		if gupscript is None:
			return False # not a buildable target
		deps = state.deps()
		if not deps:
			log.debug("DIRTY: dependency %s is buildable but has no dep information", target_path)
			return True
		return deps.is_dirty(gupscript.path)
	
class GupfileDependency(FileDependency):
	tag = 'gupfile:'
	def is_dirty(self, base, gupfile):
		assert not os.path.isabs(gupfile)
		assert not os.path.isabs(self.path)
		if gupfile != self.path:
			log.debug("DIRTY: gup file changed from %s -> %s" % (self.path, gupfile))
			return True
		return super(GupfileDependency, self).is_dirty(base, gupfile)

	def is_dependency_dirty(self, base):
		return False

