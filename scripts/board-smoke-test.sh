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
gcc_smoke_dir=$(mktemp -d /tmp/gemmont-gcc-smoke.XXXXXX)
trap 'rm -rf "${gcc_smoke_dir}"' EXIT HUP INT TERM

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

if [ "$(gcc -dumpfullversion)" != 16.1.0 ]; then
	echo "unexpected native GCC version: $(gcc -dumpfullversion)" >&2
	exit 1
fi
if [ "$(gcc -dumpmachine)" != loongarch32-linux-gnusf ]; then
	echo "unexpected native GCC target: $(gcc -dumpmachine)" >&2
	exit 1
fi
if [ "$(gcc -print-sysroot)" != /opt/gemmont-gcc-16.1.0/sysroot ]; then
	echo "unexpected native GCC sysroot: $(gcc -print-sysroot)" >&2
	exit 1
fi

cat >"${gcc_smoke_dir}/hello.c" <<'HELLO_EOF'
#include <stdio.h>

int main(void)
{
	puts("Hello from Gemmont GCC 16!");
	return 0;
}
HELLO_EOF
gcc -O0 -Wall -Wextra -Werror \
	"${gcc_smoke_dir}/hello.c" -o "${gcc_smoke_dir}/hello"
if [ "$("${gcc_smoke_dir}/hello")" != "Hello from Gemmont GCC 16!" ]; then
	echo "native GCC Hello World output mismatch" >&2
	exit 1
fi
readelf -h "${gcc_smoke_dir}/hello" |
	grep -Eq 'Flags:.*0x41([,[:space:]]|$)'
readelf -l "${gcc_smoke_dir}/hello" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'
echo "NATIVE_GCC_HELLO_OK"

cat /proc/mtd
mtdinfo -a

find "/lib/modules/${actual_release}" -name '*.ko' -print
modprobe sit
lsmod

free -m
ssh -V
echo "BOARD_TEST_DONE"
EOF
