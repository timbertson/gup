UNKNOWN_ERROR_CODE = 1

class SafeError(Exception):
	exitcode = 10
	pass

class TargetFailed(SafeError):
	def __init__(self, target, status, tempfile):
		self.target = target
		self.status = status
		extra = "" if tempfile is None else " (keeping %s for inspection)" % (tempfile,)
		super(TargetFailed, self).__init__("Target `%s` failed with exit status %s%s" % (self.target, self.status, extra))


class Unbuildable(SafeError):
	def __init__(self, path):
		super(Unbuildable, self).__init__("Don't know how to build %s" % (path,))

