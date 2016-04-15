import os
import logging
import errno

from .util import *
from .log import getLogger
from .gupfile import Builder
from .parallel import Lock
from .var import RUN_ID
_log = getLogger(__name__)

META_DIR = '.gup'

class VersionMismatch(ValueError): pass

class _dirty_args(object):
	def __init__(self, deps, base, builder_path, build_dependency):
		self.deps = deps
		self.base = base
		self.builder_path = builder_path
		self.build_dependency = build_dependency

def dirty_check_with_dep(path, check_fn, args):
	dirty = check_fn()
	if dirty: return True
	built = args.build_dependency(path)
	if built:
		_log.trace("dirty_check_with_dep: path %s was built, rechecking", path);
		return check_fn()
	else:
		return False

class TargetState(object):
	_dep_lock = None

	def __init__(self, p):
		self.path = p
	
	def __repr__(self):
		return 'TargetState(%r)' % (self.path,)
	
	@staticmethod
	def built_targets(dir):
		'''
		Returns the target names which have metadata stored in `dir`
		'''
		return [f[:-5] for f in os.listdir(dir) if f.endswith('.deps')]

	def meta_path(self, ext):
		base, target = os.path.split(self.path)
		meta_dir = os.path.join(base, META_DIR)
		return os.path.join(meta_dir, "%s.%s" % (target, ext))

	def _ensure_meta_path(self, ext):
		p = self.meta_path(ext)
		mkdirp(os.path.dirname(p))
		return p
	
	def _ensure_dep_lock(self):
		if not self._dep_lock:
			self._dep_lock = Lock(self._ensure_meta_path('deps.lock'))
		return self._dep_lock

	def deps(self):
		rv = None
		deps_path = self.meta_path('deps')
		if not os.path.exists(deps_path):
			_log.trace("Not loading missing deps at %s", deps_path)
			return rv

		with self._ensure_dep_lock().read():
			try:
				f = open(deps_path)
			except IOError as e:
				if e.errno != errno.ENOENT: raise
			else:
				try:
					with f:
						rv = Dependencies(self.path, f)
				except VersionMismatch as e:
					_log.debug("Ignoring stored dependencies from incompatible version: %s", deps_path)
				except Exception as e:
					_log.debug("Error loading %s: %s (assuming dirty)", deps_path, e)
		_log.trace("Loaded serialized state from %s: %r" % (deps_path, rv,))
		return rv

	def create_lock(self):
		if self.lockfile is None:
			self.lockfile = Lock(self.meta_path('lock'))

	def add_dependency(self, dep):
		lock = Lock(self.meta_path('deps2.lock'))
		_log.debug('add dep: %s -> %s' % (self.path, dep))
		with lock.write():
			with open(self.meta_path('deps2'), 'a') as f:
				dep.append_to(f)
	
	def mark_clobbers(self):
		self.add_dependency(ClobbersTarget())
	
	def perform_build(self, builder, do_build):
		exe = builder.path
		assert os.path.exists(exe)
		def still_needs_build(deps):
			_log.trace("checking if %s still needs build after releasing lock" % self.path)
			return deps is None or (not deps.already_built())

		with self._ensure_dep_lock().write():
			deps = self.deps()
			if not still_needs_build(deps):
				return False

			builder_dep = BuilderDependency.relative_to_target(self.path,
				path=builder.realpath,
				mtime=get_mtime(builder.realpath))

			_log.trace("created dep %s from builder %r" % (builder_dep, exe))
			temp = self._ensure_meta_path('deps2')
			with open(temp, 'w') as f:
				Dependencies.init_file(f)
				builder_dep.append_to(f)
			try:
				built = do_build(deps)
			except:
				os.remove(temp)
				raise
			else:
				if built:
					# always track the build time
					built_time = get_mtime(self.path)
					if built_time is not None:
						with open(temp, 'a') as f:
							BuildTime(built_time).append_to(f)
					rename(temp, self.meta_path('deps'))
				return built

class Dependencies(object):
	FORMAT_VERSION = 3
	def __init__(self, path, file):
		self.path = path
		self.rules = []
		self.checksum = None
		self.clobbers = False
		self.runid = None

		if file is None:
			self.rules.append(NeverBuilt())
		else:
			version_line = file.readline().strip()
			_log.trace("version_line: %s" % (version_line,))
			if not version_line.startswith('version:'): raise ValueError("Invalid file")
			_, file_version = version_line.split(' ')
			if int(file_version) != self.FORMAT_VERSION:
				raise VersionMismatch("can't read format version %s" % (file_version,))

			while True:
				line = file.readline()
				if not line: break
				dep = Dependency.parse(line.rstrip())
				if isinstance(dep, Checksum):
					assert self.checksum is None
					self.checksum = dep.value
				elif isinstance(dep, RunId):
					assert self.runid is None
					self.runid = dep
				elif isinstance(dep, ClobbersTarget):
					self.clobbers = True
				else:
					self.rules.append(dep)
	
	def is_dirty(self, builder, build_dependency):
		assert isinstance(builder, Builder)
		if not os.path.lexists(self.path):
			_log.debug("DIRTY: %s (target does not exist)", self.path)
			return True

		base = os.path.dirname(self.path)
		builder_path = os.path.relpath(builder.realpath, base)

		dirty_args = _dirty_args(deps=self, base=base, builder_path=builder_path, build_dependency=build_dependency)
		for rule in self.rules:
			d = rule.is_dirty(dirty_args)
			if d:
				_log.trace('DIRTY: %s (from rule %r)', self.path, rule)
				return True
		_log.trace('is_dirty: %s returning %r', self.path, False)
		return False
	
	def already_built(self):
		return self.runid.is_current()

	@classmethod
	def init_file(cls, f):
		f.write('version: %s\n' % (cls.FORMAT_VERSION,))
		RunId.current().append_to(f)
	
	def __repr__(self):
		return 'Dependencies<runid=%r, checksum=%s, %r>' % (self.runid, self.checksum, self.rules)

class Dependency(object):
	recursive = False
	@staticmethod
	def parse(line):
		_log.trace("parsing line: %s" % (line,))
		for candidate in [
				FileDependency,
				BuilderDependency,
				AlwaysRebuild,
				Checksum,
				RunId,
				ClobbersTarget,
				BuildTime]:
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
	def is_dirty(self, args):
		_log.debug('DIRTY: never built')
		return True
	def append_to(self, file): pass

class AlwaysRebuild(Dependency):
	tag = 'always:'
	num_fields = 0
	fields = []
	def is_dirty(self, _):
		_log.debug('DIRTY: always rebuild')
		return True

class FileDependency(Dependency):
	num_fields = 3
	tag = 'file:'
	recursive = True

	def __init__(self, mtime, checksum, path):
		self.path = path
		self.checksum = checksum
		self.mtime = mtime
	
	@classmethod
	def relative_to(cls, rel_root, mtime, path):
		rel_path = os.path.relpath(path, rel_root)
		return cls(mtime=mtime, checksum=None, path=rel_path)

	@classmethod
	def relative_to_target(cls, target, mtime, path):
		return cls.relative_to(os.path.dirname(target), mtime=mtime, path=path)
	
	@classmethod
	def of_target(cls, parent_target, target, mtime):
		rv = cls.relative_to_target(parent_target, mtime=mtime, path=target.path)
		deps = target.state.deps()
		if deps and deps.checksum:
			rv.checksum = deps.checksum
		return rv
	
	@classmethod
	def deserialize(cls, mtime, checksum, path):
		return cls(
			None if mtime == '-' else int(mtime),
			None if checksum == '-' else checksum,
			path)
	
	@property
	def fields(self):
		return [
			'-' if self.mtime is None else str(self.mtime),
			self.checksum or '-',
			self.path]

	def full_path(self, base):
		if os.path.isabs(self.path): return self.path
		return os.path.normpath(os.path.join(base, self.path))

	def is_dirty(self, args):
		base = args.base
		path = self.full_path(base)
		self._target = path

		def mtime_dirty():
			current_mtime = get_mtime(path)
			if current_mtime != self.mtime:
				_log.debug("DIRTY: %s (stored mtime is %r, current is %r)" % (self.path, self.mtime, current_mtime))
				return True
			return False
		
		dirty = dirty_check_with_dep(path, mtime_dirty, args)

		if dirty and self.checksum is not None:
			def checksum_dirty():
				_log.trace("%s: comparing using checksum %s", self.path, self.checksum)
				state = TargetState(path)
				deps = state.deps()
				checksum = deps and deps.checksum
				if checksum != self.checksum:
					_log.debug("DIRTY: %s (stored checksum is %s, current is %s)", self.path, self.checksum, checksum)
					return True
				return False

			return dirty_check_with_dep(path, checksum_dirty, args)
		else:
			return dirty

class BuilderDependency(FileDependency):
	tag = 'builder:'
	recursive = False

	def is_dirty(self, args):
		builder_path = args.builder_path

		assert not os.path.isabs(builder_path)
		assert not os.path.isabs(self.path)
		if builder_path != self.path:
			_log.debug("DIRTY: builder changed from %s -> %s" % (self.path, builder_path))
			return True
		return super(BuilderDependency, self).is_dirty(args)

class Checksum(Dependency):
	tag = 'checksum:'
	num_fields = 1

	def __init__(self, cs):
		self.value = cs
		self.fields = [cs]
	
	@staticmethod
	def _add_file(sh, f):
		if sh is None:
			import hashlib
			sh = hashlib.sha1()
		while True:
			b = f.read(4096)
			if not b: break
			sh.update(b)
		return sh

	@classmethod
	def from_stream(cls, f):
		sh = cls._add_file(None, f)
		return cls(sh.hexdigest())
	
	@classmethod
	def from_files(cls, filenames):
		sh = None
		for filename in filenames:
			with open(filename, 'rb') as f:
				sh = cls._add_file(sh, f)
		return cls(sh.hexdigest())

class BuildTime(Dependency):
	tag = 'built:'
	num_fields = 1

	def __init__(self, mtime):
		assert mtime is not None
		self.value = mtime
		self.fields = [str(mtime)]

	@classmethod
	def deserialize(cls, mtime):
		return cls(int(mtime))
	
	def is_dirty(self, args):
		path = args.deps.path

		mtime = get_mtime(path)
		assert mtime is not None
		_log.debug("comparing stored mtime %s to %s", self.value, mtime)
		if mtime != self.value:
			log_method = _log.warn
			if os.path.isdir(path):
				# dirs are modified externally for various reasons, not worth warning
				log_method = _log.debug
			log_method("%s was externally modified - rebuilding" % (path,))
			return True
		return False

class RunId(Dependency):
	tag = 'run:'
	num_fields = 1

	def __init__(self, runid):
		self.value = runid
		self.fields = [runid]

	@classmethod
	def current(cls):
		return cls(RUN_ID)

	def is_current(self):
		return self.value == RUN_ID

class ClobbersTarget(Dependency):
	tag = 'clobbers:'
	num_fields = 0
	fields = []
