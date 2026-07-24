#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${root_dir}/output"}
target_dir="${output_dir}/target"
images_dir="${output_dir}/images"

required_target_files="
/init
/bin/busybox
/usr/bin/ssh
/usr/bin/ssh-keygen
/usr/sbin/sshd
/usr/sbin/mtdinfo
/usr/sbin/nanddump
/usr/sbin/ubiattach
/usr/sbin/ubiformat
/usr/sbin/gemmont-rootfs-selftest
"

for path in ${required_target_files}; do
	if [ ! -e "${target_dir}${path}" ]; then
		echo "Missing root filesystem file: ${path}" >&2
		exit 1
	fi
done

for image in rootfs.cpio.gz rootfs.tar.zst rootfs.ubifs rootfs.ubi; do
	if [ ! -s "${images_dir}/${image}" ]; then
		echo "Missing or empty image: ${images_dir}/${image}" >&2
		exit 1
	fi
done

readelf_bin=$(find "${output_dir}/host/bin" -maxdepth 1 \
	-name 'loongarch32*-linux-gnusf-readelf' -print -quit)
if [ -z "${readelf_bin}" ]; then
	echo "Buildroot cross-readelf was not found" >&2
	exit 1
fi

gcc_bin=$(find "${output_dir}/host/bin" -maxdepth 1 \
	-name 'loongarch32*-linux-gnusf-gcc' -print -quit)
if [ -z "${gcc_bin}" ] ||
   [ "$("${gcc_bin}" -dumpfullversion)" != "16.1.0" ]; then
	echo "Root filesystem was not built with GCC 16.1.0" >&2
	exit 1
fi

elf_list=$(mktemp)
elf_header=$(mktemp)
trap 'rm -f "${elf_list}" "${elf_header}"' EXIT HUP INT TERM
find "${target_dir}" -type f -perm /111 -print >"${elf_list}"

checked=0
obj_v1=0
while IFS= read -r candidate; do
	if ! "${readelf_bin}" -h "${candidate}" >"${elf_header}" 2>/dev/null; then
		continue
	fi
	if ! grep -q 'Class:.*ELF32' "${elf_header}" ||
	   ! grep -q 'Machine:.*LoongArch' "${elf_header}" ||
	   ! grep -Eq 'Flags:.*0x(1|41)([,[:space:]]|$)' "${elf_header}"; then
		echo "Unexpected ELF ABI: ${candidate}" >&2
		cat "${elf_header}" >&2
		exit 1
	fi
	if grep -Eq 'Flags:.*0x41([,[:space:]]|$)' "${elf_header}"; then
		obj_v1=$((obj_v1 + 1))
	fi
	checked=$((checked + 1))
done <"${elf_list}"

if [ "${checked}" -eq 0 ] || [ "${obj_v1}" -eq 0 ]; then
	echo "No GCC 16 LA32R OBJ-v1 target ELF files were checked" >&2
	exit 1
fi

for candidate in /bin/busybox /usr/bin/ssh /usr/sbin/sshd; do
	if ! "${readelf_bin}" -h "${target_dir}${candidate}" 2>/dev/null |
		grep -Eq 'Flags:.*0x41([,[:space:]]|$)'; then
		echo "${candidate} was not compiled as LA32R OBJ-v1" >&2
		exit 1
	fi
	if ! "${readelf_bin}" -l "${target_dir}${candidate}" 2>/dev/null |
		grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
		echo "Unexpected dynamic loader in ${candidate}" >&2
		exit 1
	fi
done

if ! gzip -dc "${images_dir}/rootfs.cpio.gz" |
	cpio -it --quiet 2>/dev/null |
	grep -qx 'usr/sbin/sshd'; then
	echo "OpenSSH server is absent from rootfs.cpio.gz" >&2
	exit 1
fi

if ! tar --zstd -tf "${images_dir}/rootfs.tar.zst" |
	grep -qx './usr/sbin/sshd'; then
	echo "OpenSSH server is absent from rootfs.tar.zst" >&2
	exit 1
fi

echo "Root filesystem checks passed: ${checked} ELF32 LoongArch files, ${obj_v1} built as GCC 16 LA32R OBJ-v1"
