#!/bin/sh
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
gcc_version=16.1.0
binutils_version=2.46.1
target=loongarch32-linux-gnusf
toolchain_revision=2
toolchain_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-${gcc_version}-la32r"}
download_dir=${DL_DIR:-"${root_dir}/dl"}
build_dir=${TOOLCHAIN_BUILD_DIR:-"${root_dir}/.build/gcc-${gcc_version}-la32r"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}

gcc_archive="gcc-${gcc_version}.tar.xz"
gcc_url="https://ftp.gnu.org/gnu/gcc/gcc-${gcc_version}/${gcc_archive}"
gcc_sha256=50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79
binutils_archive="binutils-${binutils_version}.tar.xz"
binutils_url="https://ftp.gnu.org/gnu/binutils/${binutils_archive}"
binutils_sha256=e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4
vendor_archive=loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0.tar.xz
vendor_sha256=64856b06a2793863aa60104ef91ad04c7ba99c0de57928ceab7d31dd884ce647
vendor_path="${download_dir}/toolchain-external-custom/${vendor_archive}"
marker="${toolchain_dir}/.gemmont-gcc16-toolchain"

if [ "${jobs}" -gt 4 ]; then
	jobs=4
fi

download()
{
	url=$1
	destination=$2
	expected_sha256=$3

	mkdir -p "$(dirname -- "${destination}")"
	if [ -f "${destination}" ] &&
	   printf '%s  %s\n' "${expected_sha256}" "${destination}" |
		sha256sum -c - >/dev/null 2>&1; then
		return
	fi

	rm -f "${destination}.tmp"
	curl -fL --retry 3 --output "${destination}.tmp" "${url}"
	printf '%s  %s\n' "${expected_sha256}" "${destination}.tmp" |
		sha256sum -c -
	mv "${destination}.tmp" "${destination}"
}

toolchain_is_valid()
{
	cc="${toolchain_dir}/bin/${target}-gcc"
	cxx="${toolchain_dir}/bin/${target}-g++"
	readelf="${toolchain_dir}/bin/${target}-readelf"
	[ -x "${cc}" ] || return 1
	[ -x "${cxx}" ] || return 1
	[ -x "${readelf}" ] || return 1
	[ -f "${marker}" ] || return 1
	grep -qx "toolchain_revision=${toolchain_revision}" "${marker}" || return 1
	[ "$("${cc}" -dumpfullversion)" = "${gcc_version}" ] || return 1
	[ "$("${cc}" -dumpmachine)" = "${target}" ] || return 1
	"${cc}" -print-sysroot |
		grep -qx "${toolchain_dir}/${target}/sysroot" || return 1
	sanity_binary=$(mktemp "${TMPDIR:-/tmp}/gemmont-gcc16.XXXXXXXX")
	if ! printf '%s\n' 'int main(void) { return 0; }' |
		"${cc}" -x c - -o "${sanity_binary}" >/dev/null 2>&1; then
		rm -f "${sanity_binary}"
		return 1
	fi
	if ! "${readelf}" -h "${sanity_binary}" |
		grep -q 'Flags:.*0x41'; then
		rm -f "${sanity_binary}"
		return 1
	fi
	rm -f "${sanity_binary}"

	sanity_binary=$(mktemp "${TMPDIR:-/tmp}/gemmont-gcc16-cxx.XXXXXXXX")
	if ! printf '%s\n' \
		'#include <new>' \
		'int main() { int *p = new int(0); delete p; return 0; }' |
		"${cxx}" -x c++ - -o "${sanity_binary}" >/dev/null 2>&1; then
		rm -f "${sanity_binary}"
		return 1
	fi
	rm -f "${sanity_binary}"
}

if toolchain_is_valid; then
	echo "Using cached GCC ${gcc_version} LA32R toolchain: ${toolchain_dir}"
	exit 0
fi

for command in bison file flex make gcc g++ curl tar xz sha256sum; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "Required host command is missing: ${command}" >&2
		exit 1
	fi
done

mkdir -p "${download_dir}" "${build_dir}"
DL_DIR="${download_dir}" "${root_dir}/scripts/fetch-toolchain.sh"
printf '%s  %s\n' "${vendor_sha256}" "${vendor_path}" | sha256sum -c -
download "${binutils_url}" "${download_dir}/${binutils_archive}" \
	"${binutils_sha256}"
download "${gcc_url}" "${download_dir}/${gcc_archive}" "${gcc_sha256}"

source_dir="${build_dir}/src"
vendor_dir="${build_dir}/vendor"
binutils_source="${source_dir}/binutils-${binutils_version}"
gcc_source="${source_dir}/gcc-${gcc_version}"

rm -rf "${source_dir}" "${vendor_dir}" "${build_dir}/binutils" \
	"${build_dir}/gcc" "${toolchain_dir}"
mkdir -p "${source_dir}" "${vendor_dir}" "${toolchain_dir}"
tar -xf "${download_dir}/${binutils_archive}" -C "${source_dir}"
tar -xf "${download_dir}/${gcc_archive}" -C "${source_dir}"
tar -xf "${vendor_path}" -C "${vendor_dir}"
(
	cd "${gcc_source}"
	./contrib/download_prerequisites --no-isl
)

vendor_sysroot=$(find "${vendor_dir}" -type d \
	-path '*/loongarch32r-linux-gnusf/sysroot' -print -quit)
if [ -z "${vendor_sysroot}" ]; then
	echo "LA32R glibc sysroot was not found in ${vendor_archive}" >&2
	exit 1
fi

mkdir -p "${toolchain_dir}/${target}"
cp -a "${vendor_sysroot}" "${toolchain_dir}/${target}/sysroot"
sysroot="${toolchain_dir}/${target}/sysroot"
# Only headers and link/runtime libraries belong in a compiler sysroot.
# Remove target-side utilities, documentation and mutable state that came
# with the legacy bundle; none of its GCC 8 executables are retained.
rm -rf "${sysroot:?}/etc" "${sysroot:?}/var" \
	"${sysroot:?}/usr/bin" "${sysroot:?}/usr/sbin" \
	"${sysroot:?}/usr/libexec" "${sysroot:?}/usr/share"

mkdir -p "${build_dir}/binutils"
(
	cd "${build_dir}/binutils"
	"${binutils_source}/configure" \
		--target="${target}" \
		--prefix="${toolchain_dir}" \
		--with-sysroot="${sysroot}" \
		--disable-gdb \
		--disable-gdbserver \
		--disable-nls \
		--disable-werror
	make -j"${jobs}"
	make install
)

mkdir -p "${build_dir}/gcc"
(
	cd "${build_dir}/gcc"
	PATH="${toolchain_dir}/bin:${PATH}" \
	"${gcc_source}/configure" \
		--target="${target}" \
		--prefix="${toolchain_dir}" \
		--with-sysroot="${sysroot}" \
		--with-native-system-header-dir=/usr/include \
		--with-arch=la32rv1.0 \
		--with-tune=loongarch32 \
		--with-abi=ilp32s \
		--with-specs="-D__loongarch32r=1 -D_ABILP32=1 -D_LOONGARCH_SIM=_ABILP32" \
		--enable-languages=c,c++ \
		--enable-shared \
		--enable-threads=posix \
		--disable-bootstrap \
		--disable-libstdcxx-pch \
		--disable-multilib \
		--disable-nls \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libvtv \
		--with-system-zlib
	PATH="${toolchain_dir}/bin:${PATH}" make -j"${jobs}" all-gcc
	PATH="${toolchain_dir}/bin:${PATH}" make install-gcc
	PATH="${toolchain_dir}/bin:${PATH}" make -j"${jobs}" all-target-libgcc
	PATH="${toolchain_dir}/bin:${PATH}" make install-target-libgcc
	PATH="${toolchain_dir}/bin:${PATH}" \
		make -j"${jobs}" all-target-libstdc++-v3
	PATH="${toolchain_dir}/bin:${PATH}" make install-target-libstdc++-v3
)

cc="${toolchain_dir}/bin/${target}-gcc"
readelf="${toolchain_dir}/bin/${target}-readelf"
sanity_source="${build_dir}/sanity.c"
sanity_binary="${build_dir}/sanity"
printf '%s\n' 'int main(void) { return 0; }' >"${sanity_source}"
"${cc}" -march=la32rv1.0 -mabi=ilp32s "${sanity_source}" -o "${sanity_binary}"

if ! "${readelf}" -h "${sanity_binary}" |
	grep -q 'Flags:.*0x41'; then
	echo "GCC 16 sanity binary is not an LA32R OBJ-v1 executable" >&2
	exit 1
fi
if ! "${readelf}" -l "${sanity_binary}" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
	echo "GCC 16 sanity binary uses an unexpected dynamic loader" >&2
	exit 1
fi

# GCC and Binutils are built with debugging information by default.  Keep
# target libraries intact, but strip host-side cross tools before caching.
find "${toolchain_dir}/bin" "${toolchain_dir}/libexec" \
	"${toolchain_dir}/${target}/bin" -type f -perm /111 -print |
while IFS= read -r candidate; do
	if file "${candidate}" | grep -q 'ELF 64-bit.*x86-64'; then
		strip --strip-unneeded "${candidate}"
	fi
done

mkdir -p "${toolchain_dir}/share"
{
	printf 'toolchain_revision=%s\n' "${toolchain_revision}"
	printf 'gcc_version=%s\n' "${gcc_version}"
	printf 'binutils_version=%s\n' "${binutils_version}"
	printf 'target=%s\n' "${target}"
	printf 'arch=la32rv1.0\n'
	printf 'abi=ilp32s\n'
	printf 'languages=c,c++\n'
	printf 'libc=glibc-2.28-la32r-sysroot\n'
	printf 'compat_cpp_macros=__loongarch32r,_ABILP32,_LOONGARCH_SIM\n'
	printf 'gcc_sha256=%s\n' "${gcc_sha256}"
	printf 'binutils_sha256=%s\n' "${binutils_sha256}"
	printf 'sysroot_archive_sha256=%s\n' "${vendor_sha256}"
} >"${toolchain_dir}/share/gemmont-toolchain.manifest"
cp "${toolchain_dir}/share/gemmont-toolchain.manifest" "${marker}"

echo "Built GCC ${gcc_version} LA32R userspace toolchain: ${toolchain_dir}"
