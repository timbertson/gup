import os
import logging
import contextlib
import errno

from .util import *
from .log import getLogger
from .gupfile import Builder
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
		rv = None
		try:
			f = open(self.meta_path('deps'))
		except IOError as e:
			if e.errno != errno.ENOENT: raise
		else:
			with f:
				rv = Dependencies(self.path, f)
		log.debug("Loaded serialized state: %r" % (rv,))
		return rv

	def add_dependency(self, dep):
		log.debug('add dep: %s -> %s' % (self.path, dep))
		with open(self.meta_path('deps_next'), 'a') as f:
			dep.append_to(f)
	
	@contextlib.contextmanager
	def perform_build(self, exe):
		assert os.path.exists(exe)
		builder_dep = BuilderDependency(
			path=os.path.relpath(exe, os.path.dirname(self.path)),
			checksum=None,
			mtime=get_mtime(exe))

		log.debug("created dep %s from builder %r" % (builder_dep, exe))
		temp = self._ensure_meta_path('deps_next')
		with open(temp, 'w') as f:
			Dependencies.init_file(f)
			builder_dep.append_to(f)
		try:
			yield
		except:
			os.remove(temp)
			raise
		else:
			os.rename(temp, self.meta_path('deps'))

class Dependencies(object):
	FORMAT_VERSION = 1
	recursive = False
	def __init__(self, path, file):
		self.path = path
		self.rules = []
		self.checksum = None
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
				dep = Dependency.parse(line.rstrip())
				if isinstance(dep, Checksum):
					assert self.checksum is None
					self.checksum = dep.value
				else:
					self.rules.append(dep)
	
	def is_dirty(self, builder, built):
		assert isinstance(builder, Builder)
		if not os.path.exists(self.path):
			log.debug("DIRTY: %s (target does not exist)", self.path)
			return True
		base = os.path.dirname(self.path)
		builder_path = os.path.relpath(builder.path, base)

		unknown_states = []
		for rule in self.rules:
			d = rule.is_dirty(base, builder_path, built=built)
			if d is True:
				log.debug('DIRTY: %s (from rule %r)', self.path, rule)
				return True
			elif d is False:
				continue
			else:
				unknown_states.append(d)
		log.debug('is_dirty: %s returning %r', self.path, unknown_states or False)
		return unknown_states or False

	def children(self):
		base = os.path.dirname(self.path)
		for rule in self.rules:
			if rule.recursive:
				yield rule.full_path(base)
	
	@classmethod
	def init_file(cls, f):
		f.write('version: %s\n' % (cls.FORMAT_VERSION,))
	
	def __repr__(self):
		return 'Dependencies<%r>' % (self.rules,)

class Dependency(object):
	@staticmethod
	def parse(line):
		log.debug("parsing line: %s" % (line,))
		for candidate in [FileDependency, BuilderDependency, AlwaysRebuild, Checksum]:
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

	def __repr__(self):
		return '%s(%s)' % (type(self).__name__, ', '.join(map(repr, self.fields)))

class NeverBuilt(object):
	fields = []
	def is_dirty(self, base, builder_path, built):
		log.debug('DIRTY: never built')
		return True
	def append_to(self, file): pass

class AlwaysRebuild(Dependency):
	tag = 'always:'
	num_fields = 0
	fields = []
	def is_dirty(self, base, builder_path, built):
		log.debug('DIRTY: always rebuild')
		return True

class UnknownState(object):
	def __init__(self, target, children):
		self.target = target
		self.children = children

class FileDependency(Dependency):
	num_fields = 3
	tag = 'filedep:'
	recursive = True

	def __init__(self, mtime, checksum, path):
		self.path = path
		self.checksum = checksum
		self.mtime = mtime
	
	@classmethod
	def deserialize(cls, mtime, checksum, path):
		return cls(
			int(mtime) or None,
			None if checksum == '-' else checksum,
			path)
	
	@property
	def fields(self):
		return [
			str(self.mtime or 0),
			self.checksum or '-',
			self.path]

	def full_path(self, base):
		return os.path.join(base, self.path)

	def is_dirty(self, base, builder_path, built):
		path = self.full_path(base)
		self._target = path

		if self.checksum is not None:
			log.debug("%s: comparing using checksum", self.path)
			# use checksum only
			state = TargetState(path)
			deps = state.deps()
			checksum = deps and deps.checksum
			if deps.checksum != self.checksum:
				log.debug("DIRTY: %s (stored checksum is %s, current is %s)", self.path, self.checksum, deps.checksum)
				return True
			if built:
				return False
			# if not built, we don't actually know whether this dep is dirty
			log.debug("%s: might be dirty - returning %r", self.path, state)
			return state

		else:
			# use mtime only
			current_mtime = get_mtime(path)
			# log.debug("Compare mtime %s to %s" % (current_mtime, self.mtime))
			if current_mtime != self.mtime:
				log.debug("DIRTY: %s (stored mtime is %r, current is %r)" % (self.path, self.mtime, current_mtime))
				return True
			return False

class BuilderDependency(FileDependency):
	tag = 'builder:'
	recursive = False

	def is_dirty(self, base, builder_path, built):
		assert not os.path.isabs(builder_path)
		assert not os.path.isabs(self.path)
		if builder_path != self.path:
			log.debug("DIRTY: builder changed from %s -> %s" % (self.path, builder_path))
			return True
		return super(BuilderDependency, self).is_dirty(base, builder_path, built=built)

class Checksum(Dependency):
	tag = 'checksum:'
	num_fields = 2

	def __init__(self, cs):
		self.value = cs
		self.fields = [cs]
	
	@classmethod
	def from_stream(cls, f):
		import hashlib
		sh = hashlib.sha1()
		while 1:
			b = os.read(0, 4096)
			sh.update(b)
			if not b: break
		return cls(sh.hexdigest())

