import sys, os, errno, glob, stat, fcntl
import logging

logger = logging.getLogger(__name__)
debug = logger.info

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
		close_on_exec(self.lockfile, True)
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
				debug("%s lock failed\n", self.name)
				pass  # someone else has it locked
			else:
				raise
		else:
			debug("%s lock (try)\n", self.name)
			self.owned = kind

	def waitlock(self, kind=fcntl.LOCK_EX):
		assert(self.owned != kind)
		debug("%s lock (wait)\n", self.name)
		fcntl.lockf(self.lockfile, kind, 0, 0)
		self.owned = kind

	def unlock(self):
		if not self.owned:
			raise Exception("can't unlock %r - we don't own it" % self.name)
		fcntl.lockf(self.lockfile, fcntl.LOCK_UN, 0, 0)
		debug("%s unlock\n", self.name)
		self.owned = False
