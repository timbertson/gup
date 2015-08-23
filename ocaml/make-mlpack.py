import sys, os
src, dest = sys.argv[1:]
with open(dest, 'w') as dest:
	for fn in os.listdir(src):
		if fn.endswith('.ml'):
			fn = fn[:-3]
			fn = fn[0].upper() + fn[1:]
			dest.write(fn+'\n')
