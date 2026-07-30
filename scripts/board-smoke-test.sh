#!/bin/sh
set -eu

board_address=${BOARD_ADDRESS:-172.25.2.56}
board_user=${BOARD_USER:-root}
jump_host=${JUMP_HOST:-fpgadev}
test_peer=${TEST_PEER:-172.25.2.193}
expected_release=${EXPECTED_KERNEL_RELEASE:-7.1.4-SuperscalarCrash-la32r-v0.1.6}
connect_timeout=${SSH_CONNECT_TIMEOUT:-60}

ssh \
	-o "ProxyCommand=ssh ${jump_host} -W %h:%p" \
	-o BatchMode=yes \
	-o "ConnectTimeout=${connect_timeout}" \
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

if [ "$(awk -F: '$1 == "root" { print $7 }' /etc/passwd)" != /bin/bash ]; then
	echo "root login shell is not /bin/bash" >&2
	exit 1
fi
if ! command -v evtest >/dev/null 2>&1; then
	echo "evtest is missing" >&2
	exit 1
fi
if [ "$(grep -Ec '^tty1::respawn:/sbin/getty -L tty1 0 linux # GEMMONT_FRAMEBUFFER$' \
	/etc/inittab)" -ne 1 ]; then
	echo "framebuffer tty1 getty is missing or duplicated" >&2
	exit 1
fi
echo "LOCAL_CONSOLE_TOOLS_OK"
case "$(/bin/bash --version | sed -n '1p')" in
	'GNU bash, version 5.2.37'*)
		;;
	*)
		echo "unexpected Bash version" >&2
		exit 1
		;;
esac
case "$(fastfetch --version)" in
	'fastfetch 2.66.0 '*)
		;;
	*)
		echo "unexpected Fastfetch version" >&2
		exit 1
		;;
esac
fastfetch --logo none --structure OS:Kernel:Uptime:CPU:Memory:LocalIp
echo "BASH_FASTFETCH_OK"

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

gcc -O0 -Wall -Wextra -Werror \
	/usr/share/gemmont-examples/hello.c -o "${gcc_smoke_dir}/hello"
if [ "$("${gcc_smoke_dir}/hello")" != \
	"Hello from Gemmont GCC 16 on LA32R!" ]; then
	echo "native GCC Hello World output mismatch" >&2
	exit 1
fi
readelf -h "${gcc_smoke_dir}/hello" |
	grep -Eq 'Flags:.*0x41([,[:space:]]|$)'
readelf -l "${gcc_smoke_dir}/hello" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'
echo "NATIVE_GCC_HELLO_OK"

if [ ! -c /dev/fb0 ]; then
	echo "/dev/fb0 is missing" >&2
	exit 1
fi
gcc -O2 -Wall -Wextra -Werror \
	/usr/share/gemmont-examples/vga-colorbars.c \
	-o "${gcc_smoke_dir}/vga-colorbars"
"${gcc_smoke_dir}/vga-colorbars"
echo "VGA_FRAMEBUFFER_OK"

gcc -O2 -Wall -Wextra -Werror \
	/usr/share/gemmont-examples/lcd-colorbars.c \
	-o "${gcc_smoke_dir}/lcd-colorbars"
"${gcc_smoke_dir}/lcd-colorbars"
echo "LCD_FRAMEBUFFER_OK"

cat /proc/mtd
mtdinfo -a

find "/lib/modules/${actual_release}" -name '*.ko' -print
modprobe sit
lsmod

free -m
ssh -V
echo "BOARD_TEST_DONE"
EOF
