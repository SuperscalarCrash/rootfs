# Bash login shells do not read ~/.bashrc automatically.
if [ -r "${HOME}/.bashrc" ]; then
	. "${HOME}/.bashrc"
fi

# Keep compiler and application temporaries out of the space-constrained /tmp.
if [ ! -d "${HOME}/.tmp" ]; then
	mkdir -m 700 "${HOME}/.tmp"
fi
TMPDIR="${HOME}/.tmp"
export TMPDIR
