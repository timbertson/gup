class SafeError(Exception): pass
class TargetFailed(SafeError):
	def __init__(self, target, status):
		self.target = target
		self.status = status
		super(TargetFailed, self).__init__("Target `%s` failed with exit status %s" % (self.target, self.status))


class Unbuildable(SafeError):
	def __init__(self, path):
		super(Unbuildable, self).__init__("Unbuildable: %s" % (path,))

