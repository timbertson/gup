import tempfile

from .log import getLogger
from .error import SafeError, UNKNOWN_ERROR_CODE
_log = getLogger(__name__)
_debug = _log.trace

_jobserver = None

def _close_on_exec(fd, yes):
	fl = fcntl.fcntl(fd, fcntl.F_GETFD)
	fl &= ~fcntl.FD_CLOEXEC
	if yes:
		fl |= fcntl.FD_CLOEXEC
	fcntl.fcntl(fd, fcntl.F_SETFD, fl)

def atoi(v):
	try:
		return int(v or 0)
	except ValueError:
		return 0

def _timeout(sig, frame):
	pass

class SerialJobserver(object):
	env = None
	def __init__(self, toplevel):
		if toplevel is not None:
			self.env = {'GUP_JOBSERVER':'0'}

	def wait_all(self):
		pass

	def start_job(self, jobfn, done):
		jobfn()
		done(0)

class Job:
	def __init__(self, name, pid, donefunc):
		self.name = name
		self.pid = pid
		self.rv = None
		self.donefunc = donefunc
		
	def __repr__(self):
		return 'Job(%s,%d)' % (self.name, self.pid)

class FDJobserver(object):
	env = None
	def __init__(self, fds, toplevel):
		self.toplevel = toplevel
		self.tokens = 1
		self.fds = fds
		self.waitfds = {}
		if toplevel is not None:
			self._release(toplevel - 1)

	def _release(self, n):
		_debug('release(%d)' % n)
		self.tokens += n
		if self.tokens > 1:
			os.write(self.fds[1], b't' * (self.tokens-1))
			self.tokens = 1

	def _release_mine(self):
		assert(self.tokens >= 1)
		os.write(self.fds[1], b't')
		self.tokens -= 1

	def wait(self, want_token):
		rfds = list(self.waitfds.keys())
		if want_token:
			rfds.append(self.fds[0])
		assert(rfds)
		r,w,x = select.select(rfds, [], [])
		_debug('self.fds=%r; wfds=%r; readable: %r' % (self.fds, self.waitfds, r))
		for fd in r:
			if self.fds and fd == self.fds[0]:
				pass
			else:
				pd = self.waitfds[fd]
				_debug("done: %r" % pd.name)
				self._release(1)
				os.close(fd)
				del self.waitfds[fd]
				rv = os.waitpid(pd.pid, 0)
				assert(rv[0] == pd.pid)
				_debug("done1: rv=%r" % (rv,))
				rv = rv[1]
				if os.WIFEXITED(rv):
					pd.rv = os.WEXITSTATUS(rv)
				else:
					pd.rv = -os.WTERMSIG(rv)
				_debug("done2: rv=%d" % pd.rv)
				pd.donefunc(pd.rv)

	def _get_token(self, reason):
		"Ensure we have one token available."
		assert(self.tokens <= 1)
		while 1:
			if self.tokens >= 1:
				_debug("self.tokens is %d" % self.tokens)
				assert(self.tokens == 1)
				_debug('(%r) used my own token...' % reason)
				break
			assert(self.tokens < 1)
			_debug('(%r) waiting for tokens...' % reason)
			self.wait(want_token=1)
			if self.tokens >= 1:
				break
			assert(self.tokens < 1)
			b = self._try_read(1)
			if b == None:
				raise Exception('unexpected EOF on token read')
			if b:
				self.tokens += 1
				_debug('(%r) got a token (%r).' % (reason, b))
				break
		assert(self.tokens <= 1)

	def _try_read(self, n):
		# using djb's suggested way of doing non-blocking reads from a blocking
		# socket: http://cr.yp.to/unix/nonblock.html
		# We can't just make the socket non-blocking, because we want to be
		# compatible with GNU Make, and they can't handle it.
		fd = self.fds[0]
		r,w,x = select.select([fd], [], [], 0)
		if not r:
			return b''  # try again
		# ok, the socket is readable - but some other process might get there
		# first.  We have to set an alarm() in case our read() gets stuck.
		oldh = signal.signal(signal.SIGALRM, _timeout)
		try:
			signal.alarm(1)  # emergency fallback
			try:
				b = os.read(fd, 1)
			except OSError as e:
				if e.errno in (errno.EAGAIN, errno.EINTR):
					# interrupted or it was nonblocking
					return b''  # try again
				else:
					raise
		finally:
			signal.alarm(0)
			signal.signal(signal.SIGALRM, oldh)
		return b and b or None	# None means EOF

	def _running(self):
		"Tell if jobs are running"
		return len(self.waitfds)

	def start_job(self, jobfunc, donefunc):
		"""
		Start a job
		jobfunc:  executed in the child process
		doncfunc: executed in the parent process during a wait or wait_all call
		"""
		reason = 'build'
		assert(self.tokens <= 1)
		self._get_token(reason)
		assert(self.tokens >= 1)
		assert(self.tokens == 1)
		self.tokens -= 1
		r,w = os.pipe()
		pid = os.fork()
		if pid == 0:
			# child
			os.close(r)
			rv = 201
			try:
				try:
					rv = jobfunc() or 0
					_debug('jobfunc completed (%r, %r)' % (jobfunc,rv))
				except SafeError as e:
					_log.error("%s" % (str(e),))
					rv = SafeError.exitcode
				except KeyboardInterrupt:
					rv = SafeError.exitcode
				except Exception:
					import traceback
					traceback.print_exc()
					rv = UNKNOWN_ERROR_CODE
			finally:
				_debug('exit: %d' % rv)
				os._exit(rv)
		_close_on_exec(r, True)
		os.close(w)
		pd = Job(reason, pid, donefunc)
		self.waitfds[r] = pd

	def wait_all(self):
		"Wait for all jobs to be finished"
		failure = None
		try:
			while self._running():
				while self.tokens >= 1:
					self._release_mine()
				_debug("wait_all: wait()")
				self.wait(want_token=0)
			_debug("wait_all: empty list")
		except SafeError as e:
			failure = e

		self._get_token('self')	# get my token back
		if self.toplevel is not None:
			remaining = self.toplevel - 1
			_debug("awaiting %d free tokens" % remaining)
			while remaining > 0:
				b = self._try_read(remaining)
				remaining -= len(b)
				if not b:
					# maybe we still have outstanding jobs?
					try:
						self.wait(want_token=0)
					except SafeError as e:
						if failure is None: failure = e
			if remaining != 0:
				raise Exception('on exit: expected %d more tokens' % (remaining))

		if failure is not None:
			raise failure

class NamedPipeJobserver(object):
	env = None
	def __init__(self, path, toplevel):
		self.path = path
		self.toplevel = toplevel
		if toplevel is not None:
			self.env = {'GUP_JOBSERVER':path}

		_log.trace("opening jobserver at %s" % path)
		r = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
		w = os.open(path, os.O_WRONLY)

		# clear nonblocking flag after both ends are open:
		rflags = fcntl.fcntl(r, fcntl.F_GETFL)
		fcntl.fcntl(r, fcntl.F_SETFL, rflags & (~os.O_NONBLOCK))

		_close_on_exec(r, True)
		_close_on_exec(w, True)

		self.server = FDJobserver((r,w), toplevel)

	def wait_all(self):
		try:
			self.server.wait_all()
		finally:
			for fd in self.server.fds:
				os.close(fd)
			if self.toplevel is not None:
				_log.debug("removing jobserver (%s)" % self.path)
				os.remove(self.path)

	def start_job(self, *a): self.server.start_job(*a)



def _discover_jobserver():
	gup_server = os.getenv('GUP_JOBSERVER', None)
	if gup_server is not None:
		return SerialJobserver(None) if gup_server == '0' else NamedPipeJobserver(gup_server, None)
	# use a make jobserver, if present
	flags = ' ' + os.getenv('MAKEFLAGS', '') + ' '
	for FIND in (' --jobserver-fds=', ' --jobserver-auth='):
		ofs = flags.find(FIND)
		if ofs >= 0:
			s = flags[ofs+len(FIND):]
			(arg,junk) = s.split(' ', 1)
			(a,b) = arg.split(',', 1)
			try:
				a = atoi(a)
				b = atoi(b)
			except ValueError:
				_log.warning('invalid --jobserver-fds: %r' % arg)
				return None

			if a <= 0 or b <= 0:
				_log.warning('invalid --jobserver-fds: %r' % arg)
				return None
			try:
				fcntl.fcntl(a, fcntl.F_GETFL)
				fcntl.fcntl(b, fcntl.F_GETFL)
			except IOError as e:
				if e.errno == errno.EBADF:
					_log.debug("--jobserver-fds error (flags=%r, a=%r, b=%r)", flags, a, b, exc_info=True)
					_log.warning('broken --jobserver-fds from make; prefix your Makefile rule with a "+"')
					return None
				else:
					raise
			return FDJobserver((a,b), None)

def _create_named_pipe():
	path = os.path.join(tempfile.gettempdir(), 'gup-job-%d' % (os.getpid()))
	def create():
		os.mkfifo(path, 0o600)

	try:
		create()
	except OSError as e:
		if e.errno == errno.EEXIST:
			# if pipe already exists it must be old, so remove it
			_log.warning("removing stale jobserver file: %s" % path)
			os.remove(path)
			create()
		else: raise

	_log.trace("created jobserver at %s" % path)
	return path

def extend_build_env(env):
	if _jobserver.env is not None:
		env.update(_jobserver.env)


def wait_all():
	_jobserver.wait_all()

def start_job(jobfunc, donefunc):
	return _jobserver.start_job(jobfunc, donefunc)


try:
	import fcntl
except ImportError:
	_log.debug("fcntl not available - falling back to serial execution mode")
	class NoopContext:
		def __enter__(self): pass
		def __exit__(self, type, value, traceback): pass
	_noop_context = NoopContext()

	class _Lock(object):
		def __init__(self, name): pass
		def read(self): return _noop_context
		def write(self): return _noop_context
	
	def _setup_jobserver(*a):
		global _jobserver
		_jobserver = SerialJobserver(None)

	#XXX workaround for pychecker complaining
	# about symbol redefinition even though they're
	# in a separate if / else branch
	globs = globals()
	globs['setup_jobserver'] = _setup_jobserver
	globs['Lock'] = _Lock
else:
	import os, errno, select, signal

	def setup_jobserver(maxjobs):
		"Start the job server"
		global _jobserver
		if _jobserver is not None:
			_log.warning("tried to set up jobserver multiple times")
			return

		_debug('setup_jobserver(%s)' % maxjobs)
		if maxjobs is None:
			_jobserver = _discover_jobserver()

		if _jobserver is None:
			maxjobs = maxjobs or 1
			if maxjobs == 1:
				_debug("no need for a jobserver (--jobs=1)")
				_jobserver = SerialJobserver(maxjobs)
			else:
				_debug("new jobserver! %s" % (maxjobs))
				path = _create_named_pipe()
				_jobserver = NamedPipeJobserver(path, maxjobs)


	# FIXME: I really want to use fcntl F_SETLK, F_SETLKW, etc here.  But python
	# doesn't do the lockdata structure in a portable way, so we have to use
	# fcntl.lockf() instead.  Usually this is just a wrapper for fcntl, so it's
	# ok, but it doesn't have F_GETLK, so we can't report which pid owns the lock.
	# The makes debugging a bit harder.  When we someday port to C, we can do that.
	class LockHelper:
		def __init__(self, lock, kind):
			self.lock = lock
			self.kind = kind

		def __enter__(self):
			self.oldkind = self.lock.owned
			if self.kind != self.oldkind:
				self.lock.waitlock(self.kind)

		def __exit__(self, type, value, traceback):
			if self.kind == self.oldkind:
				pass
			elif self.oldkind:
				self.lock.waitlock(self.oldkind)
			else:
				self.lock.unlock()

	LOCK_EX = fcntl.LOCK_EX
	LOCK_SH = fcntl.LOCK_SH

	class Lock:
		def __init__(self, name):
			self.owned = False
			self.name  = name
			self.lockfile = os.open(self.name, os.O_RDWR | os.O_CREAT, 0o666)
			_close_on_exec(self.lockfile, True)
			self.shared = fcntl.LOCK_SH
			self.exclusive = fcntl.LOCK_EX

		def __del__(self):
			if self.owned:
				self.unlock()
			os.close(self.lockfile)

		def read(self):
			return LockHelper(self, fcntl.LOCK_SH)

		def write(self):
			return LockHelper(self, fcntl.LOCK_EX)

		def trylock(self, kind=fcntl.LOCK_EX):
			assert(self.owned != kind)
			try:
				fcntl.lockf(self.lockfile, kind|fcntl.LOCK_NB, 0, 0)
			except IOError as e:
				if e.errno in (errno.EAGAIN, errno.EACCES):
					_log.trace("%s lock failed", self.name)
					pass  # someone else has it locked
				else:
					raise
			else:
				_log.trace("%s lock (try)", self.name)
				self.owned = kind

		def waitlock(self, kind=fcntl.LOCK_EX):
			assert(self.owned != kind)
			_log.trace("%s lock (wait)", self.name)
			fcntl.lockf(self.lockfile, kind, 0, 0)
			self.owned = kind

		def unlock(self):
			if not self.owned:
				raise Exception("can't unlock %r - we don't own it" % self.name)
			fcntl.lockf(self.lockfile, fcntl.LOCK_UN, 0, 0)
			_log.trace("%s unlock", self.name)
			self.owned = False
