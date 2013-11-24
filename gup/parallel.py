from .log import getLogger
from .error import SafeError, UNKNOWN_ERROR_CODE
log = getLogger(__name__)

try:
	import fcntl
except ImportError:
	log.debug("fcntl not available - falling back to serial execution mode")
	jwack_fallback = True
	def _setup_jobserver(maxjobs): pass
	def _start_job(jobfunc, donefunc):
		# execute immediately
		jobfunc()
		donefunc(0)
	def _wait_all(): pass
	def _extend_build_env(env): pass

	class NoopContext:
		def __enter__(self): pass
		def __exit__(self, type, value, traceback): pass
	_noop_context = NoopContext()

	class _Lock(object):
		def __init__(self, name): pass
		def read(self): return _noop_context
		def write(self): return _noop_context
	
	#XXX workaround for pychecker complaining
	# about symbol redefinition even though they're
	# in a separate if / else branch
	globs = globals()
	globs['setup_jobserver'] = _setup_jobserver
	globs['start_job'] = _start_job
	globs['wait_all'] = _wait_all
	globs['extend_build_env'] = _extend_build_env
	globs['Lock'] = _Lock
else:
	jwack_fallback = False
	import os, errno, select, signal

	_toplevel = 0
	_mytokens = 1
	_fds = None
	_waitfds = {}
	_makeflags = None


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


	def _debug(s):
		if 0:
			import sys
			sys.stderr.write('jwack#%d: %s\n' % (os.getpid(),s))
		

	def _release(n):
		global _mytokens
		_debug('release(%d)' % n)
		_mytokens += n
		if _mytokens > 1:
			os.write(_fds[1], 't' * (_mytokens-1))
			_mytokens = 1


	def _release_mine():
		global _mytokens
		assert(_mytokens >= 1)
		os.write(_fds[1], 't')
		_mytokens -= 1


	def _timeout(sig, frame):
		pass


	def _make_pipe(startfd):
		(a,b) = os.pipe()
		fds = (fcntl.fcntl(a, fcntl.F_DUPFD, startfd),
				fcntl.fcntl(b, fcntl.F_DUPFD, startfd+1))
		os.close(a)
		os.close(b)
		return fds


	def _try_read(fd, n):
		# using djb's suggested way of doing non-blocking reads from a blocking
		# socket: http://cr.yp.to/unix/nonblock.html
		# We can't just make the socket non-blocking, because we want to be
		# compatible with GNU Make, and they can't handle it.
		r,w,x = select.select([fd], [], [], 0)
		if not r:
			return ''  # try again
		# ok, the socket is readable - but some other process might get there
		# first.  We have to set an alarm() in case our read() gets stuck.
		oldh = signal.signal(signal.SIGALRM, _timeout)
		try:
			signal.alarm(1)  # emergency fallback
			try:
				b = os.read(_fds[0], 1)
			except OSError, e:
				if e.errno in (errno.EAGAIN, errno.EINTR):
					# interrupted or it was nonblocking
					return ''  # try again
				else:
					raise
		finally:
			signal.alarm(0)
			signal.signal(signal.SIGALRM, oldh)
		return b and b or None	# None means EOF


	def extend_build_env(env):
		if _makeflags:
			_debug("setting MAKEFLAGS=%s" % (_makeflags,))
			env['MAKEFLAGS'] = _makeflags
		else:
			_debug('extend_env: no MAKEFLAGS!')

	def setup_jobserver(maxjobs):
		"Start the job server"
		global _fds, _toplevel, _makeflags
		if _fds:
			_debug("already set up")
			return	# already set up
		_debug('setup_jobserver(%d)' % maxjobs)
		flags = ' ' + os.getenv('MAKEFLAGS', '') + ' '
		FIND = ' --jobserver-fds='
		ofs = flags.find(FIND)
		if ofs >= 0:
			s = flags[ofs+len(FIND):]
			(arg,junk) = s.split(' ', 1)
			(a,b) = arg.split(',', 1)
			a = atoi(a)
			b = atoi(b)
			if a <= 0 or b <= 0:
				raise ValueError('invalid --jobserver-fds: %r' % arg)
			try:
				fcntl.fcntl(a, fcntl.F_GETFL)
				fcntl.fcntl(b, fcntl.F_GETFL)
			except IOError, e:
				if e.errno == errno.EBADF:
					log.debug("--jobserver-fds error (flags=%r, a=%r, b=%r)", flags, a, b, exc_info=True)
					raise ValueError('broken --jobserver-fds from make; prefix your Makefile rule with a "+"')
				else:
					raise
			_fds = (a,b)
		if maxjobs and not _fds:
			# need to start a new server
			_debug("new jobserver! %s" % (maxjobs))
			_toplevel = maxjobs
			_fds = _make_pipe(100)
			_release(maxjobs-1)
			_makeflags = (
				'%s --jobserver-fds=%d,%d -j'
				% (os.getenv('MAKEFLAGS'), _fds[0], _fds[1]))


	def wait(want_token):
		rfds = _waitfds.keys()
		if _fds and want_token:
			rfds.append(_fds[0])
		assert(rfds)
		r,w,x = select.select(rfds, [], [])
		_debug('_fds=%r; wfds=%r; readable: %r' % (_fds, _waitfds, r))
		for fd in r:
			if _fds and fd == _fds[0]:
				pass
			else:
				pd = _waitfds[fd]
				_debug("done: %r" % pd.name)
				_release(1)
				os.close(fd)
				del _waitfds[fd]
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


	def _has_token():
		"Return True if we have one or more tokens available"
		if _mytokens >= 1:
			return True


	def _get_token(reason):
		"Ensure we have one token available."
		global _mytokens
		assert(_mytokens <= 1)
		setup_jobserver(1)
		while 1:
			if _mytokens >= 1:
				_debug("_mytokens is %d" % _mytokens)
				assert(_mytokens == 1)
				_debug('(%r) used my own token...' % reason)
				break
			assert(_mytokens < 1)
			_debug('(%r) waiting for tokens...' % reason)
			wait(want_token=1)
			if _mytokens >= 1:
				break
			assert(_mytokens < 1)
			if _fds:
				b = _try_read(_fds[0], 1)
				if b == None:
					raise Exception('unexpected EOF on token read')
				if b:
					_mytokens += 1
					_debug('(%r) got a token (%r).' % (reason, b))
					break
		assert(_mytokens <= 1)


	def _running():
		"Tell if jobs are running"
		return len(_waitfds)


	def wait_all():
		"Wait for all jobs to be finished"
		_debug("wait_all")
		while _running():
			while _mytokens >= 1:
				_release_mine()
			_debug("wait_all: wait()")
			wait(want_token=0)
		_debug("wait_all: empty list")
		_get_token('self')	# get my token back
		if _toplevel:
			bb = ''
			while 1:
				b = _try_read(_fds[0], 8192)
				bb += b
				if not b: break
			if len(bb) != _toplevel-1:
				raise Exception('on exit: expected %d tokens; found only %r' 
								% (_toplevel-1, len(bb)))
			os.write(_fds[1], bb)


	def _force_return_tokens():
		n = len(_waitfds)
		if n:
			_debug('%d tokens left in force_return_tokens' % n)
		_debug('returning %d tokens' % n)
		for k in _waitfds.keys():
			del _waitfds[k]
		if _fds:
			_release(n)


	def _pre_job(r, w, pfn):
		os.close(r)
		if pfn:
			pfn()


	class Job:
		def __init__(self, name, pid, donefunc):
			self.name = name
			self.pid = pid
			self.rv = None
			self.donefunc = donefunc
			
		def __repr__(self):
			return 'Job(%s,%d)' % (self.name, self.pid)

				
	def start_job(jobfunc, donefunc):
		"""
		Start a job
		jobfunc:  executed in the child process
		doncfunc: executed in the parent process during a wait or wait_all call
		"""
		reason = 'build'
		global _mytokens
		assert(_mytokens <= 1)
		_get_token(reason)
		assert(_mytokens >= 1)
		assert(_mytokens == 1)
		_mytokens -= 1
		r,w = _make_pipe(50)
		pid = os.fork()
		if pid == 0:
			# child
			os.close(r)
			rv = 201
			#TODO: remove logging handlers when run in tests
			try:
				try:
					rv = jobfunc() or 0
					_debug('jobfunc completed (%r, %r)' % (jobfunc,rv))
				except SafeError as e:
					log.error("%s" % (str(e),))
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
		_waitfds[r] = pd



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
			self.lockfile = os.open(self.name, os.O_RDWR | os.O_CREAT, 0666)
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
			except IOError, e:
				if e.errno in (errno.EAGAIN, errno.EACCES):
					log.trace("%s lock failed", self.name)
					pass  # someone else has it locked
				else:
					raise
			else:
				log.trace("%s lock (try)", self.name)
				self.owned = kind

		def waitlock(self, kind=fcntl.LOCK_EX):
			assert(self.owned != kind)
			log.trace("%s lock (wait)", self.name)
			fcntl.lockf(self.lockfile, kind, 0, 0)
			self.owned = kind

		def unlock(self):
			if not self.owned:
				raise Exception("can't unlock %r - we don't own it" % self.name)
			fcntl.lockf(self.lockfile, fcntl.LOCK_UN, 0, 0)
			log.trace("%s unlock", self.name)
			self.owned = False
