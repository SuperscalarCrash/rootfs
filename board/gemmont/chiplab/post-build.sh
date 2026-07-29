#!/bin/sh
set -eu

target_dir=${1:?missing Buildroot target directory}

install -d -m 0700 "${target_dir}/root/.ssh"
install -d -m 0755 "${target_dir}/etc/ssh/sshd_config.d"
chmod 0600 "${target_dir}/root/.ssh/authorized_keys"
chmod 0600 "${target_dir}/etc/ssh/sshd_config"

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
