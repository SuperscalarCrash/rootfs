#!/bin/sh
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${root_dir}/output"}
toolchain_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-16.1.0-la32r"}
target_dir="${output_dir}/target"
images_dir="${output_dir}/images"
native_prefix=/opt/gemmont-gcc-16.1.0
native_target=loongarch32-linux-gnusf

required_target_files="
/init
/bin/bash
/bin/busybox
/root/.bash_profile
/root/.bashrc
/root/.config/fastfetch/config.jsonc
/usr/bin/fastfetch
/usr/share/fastfetch/logos/zju-qiushi-eagle.txt
/usr/bin/gcc
/usr/bin/cc
/usr/bin/as
/usr/bin/ld
/usr/bin/ssh
/usr/bin/ssh-keygen
/usr/sbin/sshd
/usr/sbin/mtdinfo
/usr/sbin/nanddump
/usr/sbin/ubiattach
/usr/sbin/ubiformat
/usr/sbin/gemmont-rootfs-selftest
/usr/share/gemmont-examples/hello.c
/usr/share/gemmont-examples/vga-colorbars.c
/usr/share/gemmont-examples/lcd-colorbars.c
/usr/share/gemmont-examples/README
${native_prefix}/bin/gcc
${native_prefix}/bin/as
${native_prefix}/bin/ld
${native_prefix}/libexec/gcc/${native_target}/16.1.0/cc1
${native_prefix}/lib/gcc/${native_target}/16.1.0/libgcc.a
${native_prefix}/sysroot/usr/include/stdio.h
${native_prefix}/sysroot/usr/lib32/sf/crt1.o
${native_prefix}/sysroot/usr/lib32/sf/crti.o
${native_prefix}/sysroot/usr/lib32/sf/crtn.o
/usr/share/gemmont-toolchain/native-toolchain.manifest
/usr/share/licenses/gemmont-native-toolchain/gcc-COPYING3
"

for path in ${required_target_files}; do
	if [ ! -e "${target_dir}${path}" ]; then
		echo "Missing root filesystem file: ${path}" >&2
		exit 1
	fi
done

if [ "$(awk -F: '$1 == "root" { print $7 }' "${target_dir}/etc/passwd")" != \
	/bin/bash ]; then
	echo "Root login shell is not /bin/bash" >&2
	exit 1
fi

for link_mapping in gcc:gcc cc:gcc as:as ld:ld; do
	link=${link_mapping%%:*}
	target=${link_mapping#*:}
	if [ "$(readlink "${target_dir}/usr/bin/${link}")" != \
		"../../${native_prefix#/}/bin/${target}" ]; then
		echo "Unexpected /usr/bin/${link} link target" >&2
		exit 1
	fi
done

for image in rootfs.cpio.gz rootfs.tar.zst rootfs.ubifs rootfs.ubi; do
	if [ ! -s "${images_dir}/${image}" ]; then
		echo "Missing or empty image: ${images_dir}/${image}" >&2
		exit 1
	fi
done

readelf_bin="${toolchain_dir}/bin/${native_target}-readelf"
gcc_bin="${toolchain_dir}/bin/${native_target}-gcc"
if [ ! -x "${readelf_bin}" ] || [ ! -x "${gcc_bin}" ]; then
	echo "GCC 16 LA32R cross-toolchain was not found at ${toolchain_dir}" >&2
	exit 1
fi

if [ "$("${gcc_bin}" -dumpfullversion)" != "16.1.0" ]; then
	echo "Root filesystem was not built with GCC 16.1.0" >&2
	exit 1
fi

elf_list=$(mktemp)
elf_header=$(mktemp)
sanity_source=$(mktemp)
sanity_binary=$(mktemp)
trap 'rm -f "${elf_list}" "${elf_header}" "${sanity_source}" "${sanity_binary}"' \
	EXIT HUP INT TERM
find "${target_dir}" -type f \
	\( -perm -0100 -o -perm -0010 -o -perm -0001 \) \
	-print >"${elf_list}"

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

for candidate in \
	/bin/bash \
	/bin/busybox \
	/usr/bin/fastfetch \
	/usr/bin/ssh \
	/usr/sbin/sshd; do
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

for candidate in \
	"${native_prefix}/bin/gcc" \
	"${native_prefix}/bin/as" \
	"${native_prefix}/bin/ld" \
	"${native_prefix}/libexec/gcc/${native_target}/16.1.0/cc1"; do
	if ! "${readelf_bin}" -h "${target_dir}${candidate}" 2>/dev/null |
		grep -Eq 'Flags:.*0x41([,[:space:]]|$)'; then
		echo "${candidate} is not a native GCC 16 LA32R OBJ-v1 tool" >&2
		exit 1
	fi
	if ! "${readelf_bin}" -l "${target_dir}${candidate}" 2>/dev/null |
		grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
		echo "Unexpected dynamic loader in ${candidate}" >&2
		exit 1
	fi
done

printf '%s\n' \
	'#include <stdio.h>' \
	'int main(void) { puts("Hello from Gemmont GCC 16!"); return 0; }' \
	>"${sanity_source}"
"${gcc_bin}" \
	--sysroot="${target_dir}${native_prefix}/sysroot" \
	-march=la32rv1.0 -mabi=ilp32s \
	-x c "${sanity_source}" -o "${sanity_binary}"
if ! "${readelf_bin}" -h "${sanity_binary}" |
	grep -Eq 'Flags:.*0x41([,[:space:]]|$)'; then
	echo "Packaged native development sysroot produced the wrong ELF ABI" >&2
	exit 1
fi
if ! "${readelf_bin}" -l "${sanity_binary}" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
	echo "Packaged native development sysroot selected the wrong loader" >&2
	exit 1
fi

for archive_entry in \
	bin/bash \
	root/.bash_profile \
	root/.bashrc \
	root/.config/fastfetch/config.jsonc \
	usr/bin/fastfetch \
	usr/share/fastfetch/logos/zju-qiushi-eagle.txt \
	usr/share/gemmont-examples/hello.c \
	usr/share/gemmont-examples/vga-colorbars.c \
	usr/share/gemmont-examples/lcd-colorbars.c \
	usr/share/gemmont-examples/README \
	usr/sbin/sshd \
	opt/gemmont-gcc-16.1.0/bin/gcc; do
	if ! gzip -dc "${images_dir}/rootfs.cpio.gz" |
		cpio -it --quiet 2>/dev/null |
		grep -qx "${archive_entry}"; then
		echo "${archive_entry} is absent from rootfs.cpio.gz" >&2
		exit 1
	fi

	if ! tar --zstd -tf "${images_dir}/rootfs.tar.zst" |
		grep -qx "./${archive_entry}"; then
		echo "${archive_entry} is absent from rootfs.tar.zst" >&2
		exit 1
	fi
done

echo "Root filesystem checks passed: ${checked} ELF32 LoongArch files, ${obj_v1} built as GCC 16 LA32R OBJ-v1"
