import os
import errno
from .log import getLogger
from .var import IS_WINDOWS

# _log = getLogger(__name__)

def resolve_base(p):
	return os.path.join(
		os.path.realpath(os.path.dirname(p)),
		os.path.basename(p)
	)

def traverse_from(base, rel, resolve_final=False):
	if IS_WINDOWS:
		# yeah, nah
		return ([], os.path.join(base, rel))

	if os.path.isabs(rel):
		base = '/'

	# _log.trace("traverse_from: %s, %s", base, rel)
	links = []
	parts = [part for part in rel.split(os.path.sep) if part]
	path = base
	if not parts:
		return (links, path)

	while True:
		try:
			# _log.trace("readlink: %s", path)
			dest = os.readlink(path)
		except OSError as e:
			if e.errno == errno.EINVAL:
				# not a symlink; continue along path
				path = os.path.join(path, parts.pop(0))
				if not (parts or resolve_final):
					# _log.trace("returning because there's no parts left: %s, %s", links, path)
					return (links, path)
			elif e.errno == errno.ENOENT:
				# doesn't exist, return the entire
				# remaining path
				return (links, os.path.join(path, *parts))
			else:
				raise
		else:
			# _log.trace("->: %s", dest)
			links.append(path)
			if os.path.isabs(dest):
				path = dest
			else:
				# relative dest
				path = os.path.join(os.path.dirname(path), dest)

