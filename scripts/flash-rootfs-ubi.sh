#!/bin/sh
set -eu

usage()
{
	echo "Usage: $0 URL IMAGE_SIZE --yes-really-flash-ubi" >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
image_url=$1
image_size=$2
confirmation=$3
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
httpget=${GEMMONT_HTTPGET:-"${script_dir}/gemmont-httpget"}

case "${image_url}" in
	http://*) ;;
	*) echo "The image URL must use HTTP." >&2; exit 2 ;;
esac
case "${image_size}" in
	''|*[!0-9]*|0) echo "IMAGE_SIZE must be a positive byte count." >&2; exit 2 ;;
esac
[ "${confirmation}" = "--yes-really-flash-ubi" ] || usage
[ -x "${httpget}" ] || {
	echo "The streaming helper ${httpget} is missing or not executable." >&2
	exit 1
}

mtd_number=$(
	sed -n 's/^mtd\([0-9][0-9]*\): 06c00000 00020000 "ubi"$/\1/p' \
		/proc/mtd
)
if [ -z "${mtd_number}" ]; then
	echo "Refusing to flash: the expected 108 MiB mtd \"ubi\" partition was not found." >&2
	exit 1
fi
mtd_device="/dev/mtd${mtd_number}"

if grep -q ' ubi[0-9][0-9]*:rootfs ' /proc/mounts; then
	echo "Refusing to flash: ubi:rootfs is mounted; unmount it first." >&2
	exit 1
fi

for ubi_path in /sys/class/ubi/ubi[0-9]*; do
	[ -d "${ubi_path}" ] || continue
	if [ "$(cat "${ubi_path}/mtd_num")" = "${mtd_number}" ]; then
		ubidetach /dev/ubi_ctrl -m "${mtd_number}"
		break
	fi
done

echo "Flashing ${image_size} bytes from ${image_url} to ${mtd_device}..."
set -o pipefail
"${httpget}" "${image_url}" "${image_size}" |
	ubiformat -q -y -f - -S "${image_size}" "${mtd_device}"
sync

ubiattach /dev/ubi_ctrl -m "${mtd_number}"
ubi_number=
for ubi_path in /sys/class/ubi/ubi[0-9]*; do
	[ -d "${ubi_path}" ] || continue
	if [ "$(cat "${ubi_path}/mtd_num")" = "${mtd_number}" ]; then
		ubi_number=${ubi_path##*ubi}
		break
	fi
done
if [ -z "${ubi_number}" ]; then
	echo "The flashed partition did not attach as UBI." >&2
	exit 1
fi

ubinfo -d "${ubi_number}" -N rootfs

check_mount=/mnt/gemmont-rootfs-check
mkdir -p "${check_mount}"
mount -t ubifs -o ro "ubi${ubi_number}:rootfs" "${check_mount}"
trap 'umount "${check_mount}" 2>/dev/null || true' EXIT HUP INT TERM

for required in \
	/sbin/init \
	/usr/bin/gcc \
	/usr/bin/ld \
	/usr/libexec/gcc/loongarch32-linux-gnusf/16.1.0/cc1
do
	if [ ! -e "${check_mount}${required}" ]; then
		echo "Flashed rootfs is missing ${required}." >&2
		exit 1
	fi
done

echo "UBI rootfs flashed and checked successfully."
