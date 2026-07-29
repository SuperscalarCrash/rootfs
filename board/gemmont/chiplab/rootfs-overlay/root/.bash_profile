# Bash login shells do not read ~/.bashrc automatically.
if [ -r "${HOME}/.bashrc" ]; then
	. "${HOME}/.bashrc"
fi
