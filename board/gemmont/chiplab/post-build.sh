#!/bin/sh
set -eu

target_dir=${1:?missing Buildroot target directory}
inittab="${target_dir}/etc/inittab"

install -d -m 0700 "${target_dir}/root/.ssh"
install -d -m 0755 "${target_dir}/etc/ssh/sshd_config.d"
chmod 0600 "${target_dir}/root/.ssh/authorized_keys"
chmod 0600 "${target_dir}/etc/ssh/sshd_config"

if [ ! -f "${inittab}" ]; then
	echo "BusyBox inittab is missing from the target root filesystem" >&2
	exit 1
fi

# Buildroot creates the ttyS0 getty selected by the defconfig.  Add a second,
# independent getty for the framebuffer virtual terminal used by VGA and a
# PS/2 keyboard.  Replace any existing tty1 entry so repeated post-build
# invocations remain deterministic and never start competing getty processes.
sed -i \
	'/^# Gemmont framebuffer console$/d; /^tty1::/d' \
	"${inittab}"
cat >>"${inittab}" <<'EOF'

# Gemmont framebuffer console
tty1::respawn:/sbin/getty -L tty1 0 linux # GEMMONT_FRAMEBUFFER
EOF

if [ ! -x "${target_dir}/bin/bash" ]; then
	echo "Bash is missing from the target root filesystem" >&2
	exit 1
fi

root_shell=$(
	awk -F: '$1 == "root" { print $7 }' "${target_dir}/etc/passwd"
)
case "${root_shell}" in
	/bin/bash)
		;;
	/bin/sh)
		sed -i \
			's#^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/bin/sh$#\1/bin/bash#' \
			"${target_dir}/etc/passwd"
		;;
	*)
		echo "Unexpected root login shell: ${root_shell}" >&2
		exit 1
		;;
esac

if [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]; then
	if [ ! -s "${SSH_AUTHORIZED_KEYS_FILE}" ]; then
		echo "SSH_AUTHORIZED_KEYS_FILE is not a readable, non-empty file: ${SSH_AUTHORIZED_KEYS_FILE}" >&2
		exit 1
	fi
	install -m 0600 "${SSH_AUTHORIZED_KEYS_FILE}" \
		"${target_dir}/root/.ssh/authorized_keys"
fi

if [ -n "${LINUX_RELEASE_ARCHIVE:-}" ]; then
	"$(dirname "$0")/../../../scripts/install-kernel-modules.sh" \
		"${LINUX_RELEASE_ARCHIVE}" "${target_dir}"
fi
