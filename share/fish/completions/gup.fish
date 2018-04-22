complete -e -c gup
if gup --features | grep -q 'command-completion'
	complete -c gup --no-files --arguments '(gup --complete-command (commandline --current-token) 2>/dev/null)'
end
