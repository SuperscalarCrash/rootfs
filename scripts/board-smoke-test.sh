#!/bin/sh
set -eu

board_address=${BOARD_ADDRESS:-172.25.2.56}
board_user=${BOARD_USER:-root}
jump_host=${JUMP_HOST:-fpgadev}
test_peer=${TEST_PEER:-172.25.2.193}
expected_release=${EXPECTED_KERNEL_RELEASE:-7.1.4-chiplab-la32r}
connect_timeout=${SSH_CONNECT_TIMEOUT:-60}
control_path=${SSH_CONTROL_PATH:-}
skip_kernel_module_tests=${SKIP_KERNEL_MODULE_TESTS:-0}

case "${skip_kernel_module_tests}" in
	0|1)
		;;
	*)
		echo "SKIP_KERNEL_MODULE_TESTS must be 0 or 1" >&2
		exit 1
		;;
esac

if [ -n "${control_path}" ]; then
	set -- -S "${control_path}" -o ControlMaster=no
else
	set -- -o "ProxyCommand=ssh ${jump_host} -W %h:%p"
fi

ssh "$@" \
	-o BatchMode=yes \
	-o "ConnectTimeout=${connect_timeout}" \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	"${board_user}@${board_address}" \
	sh -s -- "${expected_release}" "${test_peer}" \
	"${skip_kernel_module_tests}" <<'EOF'
set -eu

expected_release=$1
test_peer=$2
skip_kernel_module_tests=$3
actual_release=$(uname -r)
gcc_smoke_dir="/root/.gemmont-rootfs-smoke.$$"
x11_client_pids=
mkdir -m 700 "${gcc_smoke_dir}"
mkdir -m 700 "${gcc_smoke_dir}/tmp" "${gcc_smoke_dir}/tmux"
export TMPDIR="${gcc_smoke_dir}/tmp"
export TMUX_TMPDIR="${gcc_smoke_dir}/tmux"
cleanup()
{
	for client_pid in ${x11_client_pids}; do
		kill "${client_pid}" 2>/dev/null || true
	done
	rm -rf "${gcc_smoke_dir}"
}
trap cleanup EXIT HUP INT TERM

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

printf 'alpha\nbeta\n' | grep -qx beta
tree --version | sed -n '1p'
echo "GREP_TREE_OK"

coremark >"${gcc_smoke_dir}/coremark.log"
cat "${gcc_smoke_dir}/coremark.log"
grep -q 'Correct operation validated' "${gcc_smoke_dir}/coremark.log"
grep -Eq '^CoreMark 1\.0[[:space:]]*:' "${gcc_smoke_dir}/coremark.log"

dhrystone 1000000 >"${gcc_smoke_dir}/dhrystone.log"
cat "${gcc_smoke_dir}/dhrystone.log"
grep -q 'Dhrystone Benchmark, Version 2.1' \
	"${gcc_smoke_dir}/dhrystone.log"
grep -q 'Final values of the variables used in the benchmark:' \
	"${gcc_smoke_dir}/dhrystone.log"
grep -Eq '^Int_Glob:[[:space:]]+5$' "${gcc_smoke_dir}/dhrystone.log"
grep -Eq '^Bool_Glob:[[:space:]]+1$' "${gcc_smoke_dir}/dhrystone.log"
grep -Eq '^Arr_1_Glob\[8\]:[[:space:]]+7$' \
	"${gcc_smoke_dir}/dhrystone.log"
grep -Eq '^Arr_2_Glob\[8\]\[7\]:[[:space:]]+1000010$' \
	"${gcc_smoke_dir}/dhrystone.log"
grep -q 'Dhrystones per Second:' "${gcc_smoke_dir}/dhrystone.log"
echo "CPU_BENCHMARKS_OK"

case "$(htop --version | sed -n '1p')" in
	'htop 3.5.1'*)
		;;
	*)
		echo "unexpected htop version" >&2
		exit 1
		;;
esac
case "$(tmux -V)" in
	'tmux 3.6b')
		;;
	*)
		echo "unexpected tmux version" >&2
		exit 1
		;;
esac
case "$(vim --version | sed -n '1p')" in
	'VIM - Vi IMproved 9.1 '*)
		;;
	*)
		echo "unexpected Vim version" >&2
		exit 1
		;;
esac
LC_ALL=C.UTF-8 tmux -L gemmont-smoke new-session -d -s rootfs-smoke
LC_ALL=C.UTF-8 tmux -L gemmont-smoke has-session -t rootfs-smoke
LC_ALL=C.UTF-8 tmux -L gemmont-smoke kill-server
vim --clean -es -c 'call writefile(["VIM_OK"], "/root/.vim-smoke")' -c qa
if [ "$(cat /root/.vim-smoke)" != VIM_OK ]; then
	echo "Vim batch smoke test failed" >&2
	exit 1
fi
rm -f /root/.vim-smoke
rz --version >/dev/null
sz --version >/dev/null
adb version
adbd --help >"${gcc_smoke_dir}/adbd.log" 2>&1 &
adbd_pid=$!
sleep 2
if kill -0 "${adbd_pid}" 2>/dev/null; then
	kill "${adbd_pid}"
	wait "${adbd_pid}" 2>/dev/null || true
else
	status=0
	wait "${adbd_pid}" || status=$?
	case "${status}" in
		0|1)
			;;
		*)
			echo "adbd failed to execute: ${status}" >&2
			exit 1
			;;
	esac
fi
echo "INTERACTIVE_TOOLS_ADB_OK"

ip -s link show eth0
ping -c 3 -W 2 "${test_peer}"

# /var/log and /var/cache are links into the volatile /tmp filesystem.  A
# pre-test /tmp cleanup intentionally removes these runtime directories.
mkdir -p /var/log/nginx /var/cache/nginx
nginx -t
wget -q -O "${gcc_smoke_dir}/nginx-index.html" http://127.0.0.1/
test -s "${gcc_smoke_dir}/nginx-index.html"
python3 -c '
import bz2, ctypes, json, lzma, readline, ssl, urllib.request, zlib
assert json.loads("{\"la32r\": true}")["la32r"]
callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int)(lambda value: value + 1)
assert callback(41) == 42
assert urllib.request.urlopen("http://127.0.0.1/", timeout=30).status == 200
print("PYTHON_HTTP_OK")
'
ntpdate -q -u "${test_peer}"

: >"${gcc_smoke_dir}/dhclient.leases"
dhclient -d -sf /bin/true \
	-pf "${gcc_smoke_dir}/dhclient.pid" \
	-lf "${gcc_smoke_dir}/dhclient.leases" \
	eth0 >"${gcc_smoke_dir}/dhclient.log" 2>&1 &
dhclient_pid=$!
sleep 2
if ! kill -0 "${dhclient_pid}" 2>/dev/null; then
	cat "${gcc_smoke_dir}/dhclient.log" >&2
	echo "dhclient did not stay alive for its network probe" >&2
	exit 1
fi
kill "${dhclient_pid}"
wait "${dhclient_pid}" 2>/dev/null || true
echo "NETWORK_PACKAGES_OK"

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

check_framebuffer_ppm()
{
	ppm_file=$1
	IFS=' ' read -r ppm_magic ppm_width ppm_height ppm_maxval <"${ppm_file}"
	case "${ppm_magic}:${ppm_width}:${ppm_height}:${ppm_maxval}" in
		P6:[1-9]*:[1-9]*:255)
			;;
		*)
			echo "invalid framebuffer PPM header: ${ppm_magic} ${ppm_width} ${ppm_height} ${ppm_maxval}" >&2
			exit 1
			;;
	esac
	ppm_payload_size=$((ppm_width * ppm_height * 3))
	ppm_file_size=$(wc -c <"${ppm_file}")
	if [ "${ppm_file_size}" -le "${ppm_payload_size}" ] ||
	   [ "${ppm_file_size}" -gt $((ppm_payload_size + 64)) ]; then
		echo "unexpected framebuffer PPM size: ${ppm_file_size}" >&2
		exit 1
	fi
}

printf '%s' \
	'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVQoz2N8oODAQApgIkn1qIZRDUNKAwAGbAFgwFERgAAAAABJRU5ErkJggg==' |
	base64 -d >"${gcc_smoke_dir}/fbv-test.png"

for fb_number in 0 1; do
	if [ ! -c "/dev/fb${fb_number}" ]; then
		echo "/dev/fb${fb_number} is missing" >&2
		exit 1
	fi
	fb-test -f "${fb_number}" >"${gcc_smoke_dir}/fb-test-${fb_number}.log"
	grep -q '^fb-test 1\.1\.1 (rosetta)$' \
		"${gcc_smoke_dir}/fb-test-${fb_number}.log"
	fbdump -fb "/dev/fb${fb_number}" >
		"${gcc_smoke_dir}/fb${fb_number}-before-fbv.ppm"
	check_framebuffer_ppm \
		"${gcc_smoke_dir}/fb${fb_number}-before-fbv.ppm"
	FRAMEBUFFER="/dev/fb${fb_number}" \
		fbv -c -i -u -y "${gcc_smoke_dir}/fbv-test.png" \
		>"${gcc_smoke_dir}/fbv-${fb_number}.log" 2>&1
	fbdump -fb "/dev/fb${fb_number}" >
		"${gcc_smoke_dir}/fb${fb_number}-after-fbv.ppm"
	check_framebuffer_ppm \
		"${gcc_smoke_dir}/fb${fb_number}-after-fbv.ppm"
	if cmp -s "${gcc_smoke_dir}/fb${fb_number}-before-fbv.ppm" \
		"${gcc_smoke_dir}/fb${fb_number}-after-fbv.ppm"; then
		echo "fbv did not change /dev/fb${fb_number}" >&2
		exit 1
	fi
done
echo "FRAMEBUFFER_TOOLS_OK"

# NODM starts the root Fluxbox session on display :0.  Xorg may need several
# minutes to initialize on the 50 MHz FPGA, so wait without treating the slow
# startup as a failure.
x11_display=:0
x11_ready=0
x11_attempt=0
while [ "${x11_attempt}" -lt 120 ]; do
	if DISPLAY="${x11_display}" xdpyinfo \
		>"${gcc_smoke_dir}/xdpyinfo.log" 2>&1; then
		x11_ready=1
		break
	fi
	x11_attempt=$((x11_attempt + 1))
	sleep 5
done
if [ "${x11_ready}" -ne 1 ]; then
	cat "${gcc_smoke_dir}/xdpyinfo.log" >&2
	echo "Xorg display ${x11_display} did not become ready" >&2
	exit 1
fi

# virtual_size includes the stride padding (1024 pixels on the Chiplab VGA
# framebuffer), while Xorg correctly exposes the visible 640x480 mode.  Prefer
# the first advertised framebuffer mode and only fall back to virtual_size on
# drivers which do not publish modes.
expected_x11_dimensions=$(sed -n \
	's/^[A-Z]:\([0-9][0-9]*x[0-9][0-9]*\).*/\1/p' \
	/sys/class/graphics/fb0/modes | sed -n '1p')
if [ -z "${expected_x11_dimensions}" ]; then
	expected_x11_dimensions=$(tr ',' 'x' \
		</sys/class/graphics/fb0/virtual_size)
fi
if ! grep -Eq \
	"dimensions:[[:space:]]+${expected_x11_dimensions}[[:space:]]+pixels" \
	"${gcc_smoke_dir}/xdpyinfo.log"; then
	cat "${gcc_smoke_dir}/xdpyinfo.log" >&2
	echo "Xorg dimensions do not match /dev/fb0" >&2
	exit 1
fi

# The Fluxbox process exists before it has finished publishing its EWMH root
# window properties.  Wait for the window manager itself to become ready, not
# merely for its process to be forked, before launching clients.
fluxbox_ready=0
fluxbox_attempt=0
while [ "${fluxbox_attempt}" -lt 120 ]; do
	if pidof fluxbox >/dev/null &&
	   DISPLAY="${x11_display}" xprop -root _NET_SUPPORTING_WM_CHECK \
		>"${gcc_smoke_dir}/xprop-wm-ready.log" 2>&1 &&
	   grep -q '_NET_SUPPORTING_WM_CHECK(WINDOW)' \
		"${gcc_smoke_dir}/xprop-wm-ready.log"; then
		fluxbox_ready=1
		break
	fi
	fluxbox_attempt=$((fluxbox_attempt + 1))
	sleep 5
done
if [ "${fluxbox_ready}" -ne 1 ]; then
	cat "${gcc_smoke_dir}/xprop-wm-ready.log" >&2 2>/dev/null || true
	echo "Fluxbox is not ready on ${x11_display}" >&2
	exit 1
fi

DISPLAY="${x11_display}" xrandr --current \
	>"${gcc_smoke_dir}/xrandr.log"
DISPLAY="${x11_display}" xinput --list \
	>"${gcc_smoke_dir}/xinput.log"
DISPLAY="${x11_display}" xprop -root \
	>"${gcc_smoke_dir}/xprop-root.log"

DISPLAY="${x11_display}" xterm -geometry 48x8+16+16 \
	-title 'Gemmont Xterm smoke' -e /bin/sh -c \
	"echo XTERM_X11_OK >'${gcc_smoke_dir}/xterm.log'; sleep 120" &
xterm_pid=$!
DISPLAY="${x11_display}" xcalc &
xcalc_pid=$!
DISPLAY="${x11_display}" xedit "${gcc_smoke_dir}/xedit.txt" &
xedit_pid=$!
DISPLAY="${x11_display}" xclock -digital -update 1 &
xclock_pid=$!
DISPLAY="${x11_display}" xeyes &
xeyes_pid=$!
x11_client_pids="${xterm_pid} ${xcalc_pid} ${xedit_pid} ${xclock_pid} ${xeyes_pid}"

x11_client_attempt=0
while [ ! -f "${gcc_smoke_dir}/xterm.log" ] &&
      [ "${x11_client_attempt}" -lt 60 ]; do
	x11_client_attempt=$((x11_client_attempt + 1))
	sleep 5
done
if [ ! -f "${gcc_smoke_dir}/xterm.log" ] ||
   [ "$(cat "${gcc_smoke_dir}/xterm.log")" != XTERM_X11_OK ]; then
	echo "Xterm did not execute its test command" >&2
	exit 1
fi
# Give the other clients time to map their first windows after Xterm proves
# that the server is responsive.
sleep 10
for client_pid in "${xterm_pid}" "${xcalc_pid}" "${xedit_pid}" \
	"${xclock_pid}" "${xeyes_pid}"; do
	if ! kill -0 "${client_pid}" 2>/dev/null; then
		echo "X11 test client ${client_pid} exited unexpectedly" >&2
		exit 1
	fi
done

DISPLAY="${x11_display}" xwininfo -root -tree \
	>"${gcc_smoke_dir}/xwininfo.log"
grep -q 'Gemmont Xterm smoke' "${gcc_smoke_dir}/xwininfo.log"
DISPLAY="${x11_display}" xwd -root -silent \
	-out "${gcc_smoke_dir}/x11-root.xwd"
test -s "${gcc_smoke_dir}/x11-root.xwd"

kill "${xterm_pid}" "${xcalc_pid}" "${xedit_pid}" \
	"${xclock_pid}" "${xeyes_pid}"
wait "${xterm_pid}" "${xcalc_pid}" "${xedit_pid}" \
	"${xclock_pid}" "${xeyes_pid}" 2>/dev/null || true
x11_client_pids=
echo "XORG_FLUXBOX_APPLICATIONS_OK"

gcc -O2 -Wall -Wextra -Werror \
	/usr/share/gemmont-examples/lcd-colorbars.c \
	-o "${gcc_smoke_dir}/lcd-colorbars"
"${gcc_smoke_dir}/lcd-colorbars"
echo "LCD_FRAMEBUFFER_OK"

cat /proc/mtd
mtdinfo -a

if [ "${skip_kernel_module_tests}" -eq 0 ]; then
	find "/lib/modules/${actual_release}" -name '*.ko' -print
	modprobe sit
	lsmod
else
	echo "KERNEL_MODULE_TESTS_SKIPPED"
fi

free -m
ssh -V
echo "BOARD_TEST_DONE"
EOF
