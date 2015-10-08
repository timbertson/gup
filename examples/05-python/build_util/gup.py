import subprocess

def build(*targets):
	subprocess.check_call(['gup','-u'] + list(targets))

build(__file__)
