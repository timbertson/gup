class SafeError(Exception): pass
class TargetFailed(SafeError):
	def __init__(self, msg, status):
		super(TargetFailed, self).__init__(msg)
		self.status = status
class Unbuildable(SafeError): pass

