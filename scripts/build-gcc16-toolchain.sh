#!/bin/sh
set -eu

# Use a controlled host PATH so an unrelated cross-toolchain from the login
# environment can never satisfy a configure probe or enter build metadata.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
gcc_version=16.1.0
binutils_version=2.46.1
glibc_version=2.44
linux_headers_version=7.1.4
target=loongarch32-linux-gnusf
arch=la32rv1.0
abi=ilp32s
toolchain_revision=5
toolchain_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-${gcc_version}-la32r"}
download_dir=${DL_DIR:-"${root_dir}/dl"}
build_dir=${TOOLCHAIN_BUILD_DIR:-"${root_dir}/.build/gcc-${gcc_version}-la32r"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}
glibc_submodule="${root_dir}/glibc"
glibc_commit=c3a3a9808ad3ab4a3336836833f83288b672ccbf
glibc_patch="${root_dir}/patches/glibc/0001-loongarch-fix-pointer-mangling-for-la32.patch"
glibc_patch_sha256=b8c546d87011d1582c071a3ba46e0127e15a4f0a7c8a48dafad6aef4125e9d3b
linux_source=${LINUX_SOURCE_DIR:-"${root_dir}/../linux"}

gcc_archive="gcc-${gcc_version}.tar.xz"
gcc_url="https://ftp.gnu.org/gnu/gcc/gcc-${gcc_version}/${gcc_archive}"
gcc_sha256=50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79
binutils_archive="binutils-${binutils_version}.tar.xz"
binutils_url="https://ftp.gnu.org/gnu/binutils/${binutils_archive}"
binutils_sha256=e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4
marker="${toolchain_dir}/.gemmont-gcc16-toolchain"
linux_commit=$(git -C "${linux_source}" rev-parse HEAD 2>/dev/null ||
	printf 'missing')

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
	sysroot="${toolchain_dir}/${target}/sysroot"
	[ -x "${cc}" ] || return 1
	[ -x "${cxx}" ] || return 1
	[ -x "${readelf}" ] || return 1
	[ -f "${marker}" ] || return 1
	grep -qx "toolchain_revision=${toolchain_revision}" "${marker}" ||
		return 1
	grep -qx "glibc_version=${glibc_version}" "${marker}" || return 1
	grep -qx "linux_headers_version=${linux_headers_version}" "${marker}" ||
		return 1
	grep -qx "linux_source_commit=${linux_commit}" "${marker}" || return 1
	grep -qx "glibc_commit=${glibc_commit}" "${marker}" || return 1
	grep -qx "glibc_patch_sha256=${glibc_patch_sha256}" "${marker}" ||
		return 1
	[ "$("${cc}" -dumpfullversion)" = "${gcc_version}" ] || return 1
	[ "$("${cc}" -dumpmachine)" = "${target}" ] || return 1
	"${cc}" -print-sysroot | grep -qx "${sysroot}" || return 1
	grep -qx '#define LINUX_VERSION_CODE 459012' \
		"${sysroot}/usr/include/linux/version.h" || return 1
	strings "${sysroot}/lib32/sf/libc.so.6" |
		grep -q 'stable release version 2.44' || return 1
	for runtime in "${sysroot}/lib32/ld-linux-loongarch-ilp32s.so.1" \
		"${sysroot}/lib32/sf/libc.so.6"; do
		if "${toolchain_dir}/bin/${target}-objdump" -d "${runtime}" |
			grep -Eq '[[:space:]]rotri\.[dw][[:space:]]'; then
			return 1
		fi
	done
	for library in libgcc_s.so.1 libstdc++.so.6 libatomic.so.1; do
		path=$("${cxx}" -print-file-name="${library}")
		[ "${path}" != "${library}" ] && [ -f "${path}" ] || return 1
	done
	if find "${toolchain_dir}" -name 'libstdc++.so.6.0.25' -o \
		-name 'libc-2.28.so' | grep -q .; then
		return 1
	fi
}

if toolchain_is_valid; then
	echo "Using cached upstream GCC ${gcc_version}/glibc ${glibc_version} LA32R toolchain: ${toolchain_dir}"
	exit 0
fi

for command in bison file flex gawk git make gcc g++ curl tar xz sha256sum \
	python3 perl sed patch; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "Required host command is missing: ${command}" >&2
		exit 1
	fi
done

if [ ! -f "${glibc_submodule}/version.h" ] ||
   [ "$(git -C "${glibc_submodule}" rev-parse HEAD 2>/dev/null || true)" != \
	"${glibc_commit}" ]; then
	echo "Initialize the glibc submodule at glibc-${glibc_version} (${glibc_commit})." >&2
	exit 1
fi
if [ ! -f "${linux_source}/Makefile" ] ||
   ! git -C "${linux_source}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "Linux source repository is missing: ${linux_source}" >&2
	exit 1
fi
if [ "$(make -s -C "${linux_source}" kernelversion)" != \
	"${linux_headers_version}" ]; then
	echo "Expected Linux ${linux_headers_version} sources at ${linux_source}" >&2
	exit 1
fi

mkdir -p "${download_dir}" "${build_dir}"
download "${binutils_url}" "${download_dir}/${binutils_archive}" \
	"${binutils_sha256}"
download "${gcc_url}" "${download_dir}/${gcc_archive}" "${gcc_sha256}"

source_dir="${build_dir}/src"
binutils_source="${source_dir}/binutils-${binutils_version}"
gcc_source="${source_dir}/gcc-${gcc_version}"
glibc_source="${source_dir}/glibc-${glibc_version}"
linux_headers_build_dir="${build_dir}/linux-headers"
sysroot="${toolchain_dir}/${target}/sysroot"

rm -rf "${source_dir}" "${build_dir}/vendor" \
	"${build_dir}/binutils" \
	"${linux_headers_build_dir}" \
	"${build_dir}/gcc" "${build_dir}/gcc-first" "${build_dir}/glibc" \
	"${build_dir}/gcc-final" "${toolchain_dir}"
mkdir -p "${source_dir}" "${linux_headers_build_dir}" "${sysroot}"
tar -xf "${download_dir}/${binutils_archive}" -C "${source_dir}"
tar -xf "${download_dir}/${gcc_archive}" -C "${source_dir}"
mkdir -p "${glibc_source}"
git -C "${glibc_submodule}" archive "${glibc_commit}" |
	tar -xf - -C "${glibc_source}"
printf '%s  %s\n' "${glibc_patch_sha256}" "${glibc_patch}" |
	sha256sum -c -
patch -d "${glibc_source}" -p1 <"${glibc_patch}"
(
	cd "${gcc_source}"
	./contrib/download_prerequisites --no-isl
)

# Install UAPI headers from the adjacent project Linux tree before
# bootstrapping GCC.  Keep generated Kbuild files in the toolchain build
# directory so headers_install never modifies the local Linux source tree.
# This preserves its LA32R/Chiplab changes while ensuring no header or library
# from the historical Loongson Education sysroot is used.
make -C "${linux_source}" O="${linux_headers_build_dir}" ARCH=loongarch \
	INSTALL_HDR_PATH="${sysroot}/usr" headers_install

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
	make -j1 install
)

# A static C-only bootstrap compiler is sufficient to build glibc.  This is
# the same bootstrap ordering used by glibc's build-many-glibcs.py.
mkdir -p "${build_dir}/gcc-first"
(
	cd "${build_dir}/gcc-first"
	PATH="${toolchain_dir}/bin:${PATH}" \
	"${gcc_source}/configure" \
		--target="${target}" \
		--prefix="${toolchain_dir}" \
		--with-sysroot="${sysroot}" \
		--with-native-system-header-dir=/usr/include \
		--with-arch="${arch}" \
		--with-tune=loongarch32 \
		--with-abi="${abi}" \
		--with-glibc-version="${glibc_version}" \
		--enable-languages=c \
		--disable-shared \
		--disable-threads \
		--disable-bootstrap \
		--disable-libatomic \
		--disable-decimal-float \
		--disable-gcov \
		--disable-libffi \
		--disable-libgomp \
		--disable-libitm \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-multilib \
		--disable-nls \
		--without-headers \
		--with-newlib \
		--with-system-zlib
	PATH="${toolchain_dir}/bin:${PATH}" \
		make -j"${jobs}" all-gcc all-target-libgcc
	PATH="${toolchain_dir}/bin:${PATH}" make -j1 install-gcc
	PATH="${toolchain_dir}/bin:${PATH}" make -j1 install-target-libgcc
)

build_triplet=$("${gcc_source}/config.guess")
mkdir -p "${build_dir}/glibc"
(
	cd "${build_dir}/glibc"
	PATH="${toolchain_dir}/bin:${PATH}" \
	CC="${target}-gcc -march=${arch} -mabi=${abi}" \
	CXX="${target}-g++ -march=${arch} -mabi=${abi}" \
	AR="${target}-ar" AS="${target}-as" LD="${target}-ld" \
	NM="${target}-nm" RANLIB="${target}-ranlib" \
	"${glibc_source}/configure" \
		--build="${build_triplet}" \
		--host="${target}" \
		--prefix=/usr \
		--with-headers="${sysroot}/usr/include" \
		--enable-kernel=6.19.0 \
		--disable-werror
	PATH="${toolchain_dir}/bin:${PATH}" make -j"${jobs}"
	PATH="${toolchain_dir}/bin:${PATH}" \
		make -j1 install install_root="${sysroot}"
)

# Rebuild the complete C/C++ compiler against glibc 2.44.  In particular,
# libgcc_s, libstdc++ and libatomic are now generated from GCC 16 sources.
mkdir -p "${build_dir}/gcc-final"
(
	cd "${build_dir}/gcc-final"
	PATH="${toolchain_dir}/bin:${PATH}" \
	"${gcc_source}/configure" \
		--target="${target}" \
		--prefix="${toolchain_dir}" \
		--with-sysroot="${sysroot}" \
		--with-native-system-header-dir=/usr/include \
		--with-arch="${arch}" \
		--with-tune=loongarch32 \
		--with-abi="${abi}" \
		--enable-languages=c,c++ \
		--enable-shared \
		--enable-threads=posix \
		--disable-bootstrap \
		--disable-libstdcxx-pch \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libvtv \
		--disable-multilib \
		--disable-nls \
		--with-system-zlib
	PATH="${toolchain_dir}/bin:${PATH}" make -j"${jobs}" \
		all-gcc all-target-libgcc all-target-libstdc++-v3 \
		all-target-libatomic
	PATH="${toolchain_dir}/bin:${PATH}" make -j1 install-gcc
	PATH="${toolchain_dir}/bin:${PATH}" make -j1 install-target-libgcc
	PATH="${toolchain_dir}/bin:${PATH}" \
		make -j1 install-target-libstdc++-v3
	PATH="${toolchain_dir}/bin:${PATH}" make -j1 install-target-libatomic
)

cc="${toolchain_dir}/bin/${target}-gcc"
cxx="${toolchain_dir}/bin/${target}-g++"
readelf="${toolchain_dir}/bin/${target}-readelf"
sanity_source="${build_dir}/sanity.c"
sanity_binary="${build_dir}/sanity"
printf '%s\n' 'int main(void) { return 0; }' >"${sanity_source}"
"${cc}" "${sanity_source}" -o "${sanity_binary}"

if ! "${readelf}" -h "${sanity_binary}" | grep -q 'Flags:.*0x41'; then
	echo "GCC 16 sanity binary is not an LA32R OBJ-v1 executable" >&2
	exit 1
fi
if ! "${readelf}" -l "${sanity_binary}" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
	echo "GCC 16 sanity binary uses an unexpected dynamic loader" >&2
	exit 1
fi

sanity_cxx_source="${build_dir}/sanity.cc"
sanity_cxx_binary="${build_dir}/sanity-cxx"
printf '%s\n' \
	'#include <atomic>' \
	'#include <string>' \
	'int main() { std::atomic<unsigned long long> v{1}; return std::string("upstream").size() == v.load() ? 0 : 1; }' \
	>"${sanity_cxx_source}"
"${cxx}" "${sanity_cxx_source}" -latomic -o "${sanity_cxx_binary}"

if find "${toolchain_dir}" \( -name 'libc-2.28.so' -o \
	-name 'libstdc++.so.6.0.25' \) -print -quit | grep -q .; then
	echo "Legacy Loongson Education runtime files leaked into the toolchain" >&2
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
	printf 'glibc_version=%s\n' "${glibc_version}"
	printf 'glibc_commit=%s\n' "${glibc_commit}"
	printf 'glibc_patch_sha256=%s\n' "${glibc_patch_sha256}"
	printf 'linux_headers_version=%s\n' "${linux_headers_version}"
	printf 'linux_source_commit=%s\n' "${linux_commit}"
	printf 'target=%s\n' "${target}"
	printf 'arch=%s\n' "${arch}"
	printf 'abi=%s\n' "${abi}"
	printf 'languages=c,c++\n'
	printf 'provenance=upstream-with-la32-fix\n'
	printf 'gcc_sha256=%s\n' "${gcc_sha256}"
	printf 'binutils_sha256=%s\n' "${binutils_sha256}"
} >"${toolchain_dir}/share/gemmont-toolchain.manifest"
cp "${toolchain_dir}/share/gemmont-toolchain.manifest" "${marker}"

toolchain_is_valid
echo "Built upstream GCC ${gcc_version}/glibc ${glibc_version} LA32R toolchain: ${toolchain_dir}"
