#!/bin/sh
set -eu

board_address=${BOARD_ADDRESS:-172.25.2.56}
board_user=${BOARD_USER:-root}
jump_host=${JUMP_HOST:-fpgadev}
test_peer=${TEST_PEER:-172.25.2.193}
expected_release=${EXPECTED_KERNEL_RELEASE:-7.1.4-SuperscalarCrach-la32r-v0.1.1}

ssh \
	-o "ProxyCommand=ssh ${jump_host} -W %h:%p" \
	-o BatchMode=yes \
	-o ConnectTimeout=10 \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	"${board_user}@${board_address}" \
	sh -s -- "${expected_release}" "${test_peer}" <<'EOF'
set -eu

expected_release=$1
test_peer=$2
actual_release=$(uname -r)

if [ "${actual_release}" != "${expected_release}" ]; then
	echo "kernel release mismatch: ${actual_release} != ${expected_release}" >&2
	exit 1
fi

echo "SSH_TRANSPORT_OK"
uname -a
cat /etc/os-release
gemmont-rootfs-selftest

ip -s link show eth0
ping -c 3 -W 2 "${test_peer}"

sshd -t
echo "SSHD_CONFIG_OK"

cat /proc/mtd
mtdinfo -a

find "/lib/modules/${actual_release}" -name '*.ko' -print
modprobe sit
lsmod

free -m
ssh -V
echo "BOARD_TEST_DONE"
EOF
