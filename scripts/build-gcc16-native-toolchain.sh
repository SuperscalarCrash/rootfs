#!/bin/sh
set -eu

# Keep the build independent from cross-toolchains inherited from the login
# environment.  Only the freshly built GCC 16 prefix is added below.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
gcc_version=16.1.0
binutils_version=2.46.1
glibc_version=2.44
glibc_commit=c3a3a9808ad3ab4a3336836833f83288b672ccbf
glibc_patch_sha256=b8c546d87011d1582c071a3ba46e0127e15a4f0a7c8a48dafad6aef4125e9d3b
linux_headers_version=7.1.4
zlib_version=1.3.2
target=loongarch32-linux-gnusf
arch=la32rv1.0
abi=ilp32s
toolchain_revision=5
native_prefix="/opt/gemmont-gcc-${gcc_version}"
cross_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-${gcc_version}-la32r"}
native_dir=${GCC16_NATIVE_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-${gcc_version}-la32r-native"}
download_dir=${DL_DIR:-"${root_dir}/dl"}
build_dir=${NATIVE_TOOLCHAIN_BUILD_DIR:-"${root_dir}/.build/gcc-${gcc_version}-la32r-native"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}

gcc_archive="gcc-${gcc_version}.tar.xz"
gcc_sha256=50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79
binutils_archive="binutils-${binutils_version}.tar.xz"
binutils_sha256=e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4
zlib_archive="zlib-${zlib_version}.tar.gz"
zlib_url="https://github.com/madler/zlib/releases/download/v${zlib_version}/${zlib_archive}"
zlib_sha256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
marker="${native_dir}/.gemmont-gcc16-native-toolchain"
glibc_source="${root_dir}/glibc"
linux_source=${LINUX_SOURCE_DIR:-"${root_dir}/../linux"}
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

native_toolchain_is_valid()
{
	prefix="${native_dir}/rootfs${native_prefix}"
	objdump="${cross_dir}/bin/${target}-objdump"
	[ -f "${marker}" ] || return 1
	[ -x "${objdump}" ] || return 1
	grep -qx "toolchain_revision=${toolchain_revision}" "${marker}" ||
		return 1
	grep -qx "gcc_version=${gcc_version}" "${marker}" || return 1
	grep -qx "binutils_version=${binutils_version}" "${marker}" ||
		return 1
	grep -qx "glibc_version=${glibc_version}" "${marker}" || return 1
	grep -qx "glibc_commit=${glibc_commit}" "${marker}" || return 1
	grep -qx "glibc_patch_sha256=${glibc_patch_sha256}" "${marker}" ||
		return 1
	grep -qx "linux_headers_version=${linux_headers_version}" "${marker}" ||
		return 1
	grep -qx "linux_source_commit=${linux_commit}" "${marker}" || return 1
	grep -qx "target=${target}" "${marker}" || return 1
	grep -qx "arch=${arch}" "${marker}" || return 1
	grep -qx "abi=${abi}" "${marker}" || return 1
	grep -qx "prefix=${native_prefix}" "${marker}" || return 1
	for program in addr2line ar as c++filt cpp gcc ld nm objcopy objdump \
		ranlib readelf size strings strip; do
		[ -x "${prefix}/bin/${program}" ] || return 1
	done
	for path in \
		"${prefix}/libexec/gcc/${target}/${gcc_version}/cc1" \
		"${prefix}/lib/gcc/${target}/${gcc_version}/libgcc.a" \
		"${prefix}/sysroot/usr/include/stdio.h" \
		"${prefix}/sysroot/usr/lib32/sf/crt1.o" \
		"${prefix}/sysroot/usr/lib32/sf/crti.o" \
		"${prefix}/sysroot/usr/lib32/sf/crtn.o" \
		"${prefix}/sysroot/usr/lib32/sf/libc.so" \
		"${prefix}/sysroot/usr/lib32/sf/libc_nonshared.a" \
		"${prefix}/sysroot/usr/lib32/sf/libpthread.a"; do
		[ -e "${path}" ] || return 1
	done
	[ ! -e "${prefix}/sysroot/usr/lib32/sf/libc.a" ] || return 1
	[ ! -e "${prefix}/lib/gcc/${target}/${gcc_version}/plugin" ] ||
		return 1
	strings "${prefix}/sysroot/lib32/sf/libc.so.6" |
		grep -q 'stable release version 2.44' || return 1
	for runtime in "${prefix}/sysroot/lib32/ld-linux-loongarch-ilp32s.so.1" \
		"${prefix}/sysroot/lib32/sf/libc.so.6"; do
		if "${objdump}" -d "${runtime}" |
			grep -Eq '[[:space:]]rotri\.[dw][[:space:]]'; then
			return 1
		fi
	done
	if find "${prefix}" \( -name 'libc-2.28.so' -o \
		-name 'libstdc++.so.6.0.25' \) -print -quit | grep -q .; then
		return 1
	fi
}

if native_toolchain_is_valid; then
	echo "Using cached GCC ${gcc_version} LA32R native toolchain: ${native_dir}"
	exit 0
fi

if [ "$(uname -s)" != Linux ]; then
	echo "The LA32R native toolchain must be built on Linux." >&2
	exit 1
fi

for command in bison curl file flex g++ gcc git make makeinfo sha256sum \
	strings tar xz; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		echo "Required host command is missing: ${command}" >&2
		exit 1
	fi
done

DL_DIR="${download_dir}" GCC16_TOOLCHAIN_DIR="${cross_dir}" \
	"${root_dir}/scripts/build-gcc16-toolchain.sh"

cross_gcc="${cross_dir}/bin/${target}-gcc"
cross_gxx="${cross_dir}/bin/${target}-g++"
cross_ar="${cross_dir}/bin/${target}-ar"
cross_as="${cross_dir}/bin/${target}-as"
cross_ld="${cross_dir}/bin/${target}-ld"
cross_nm="${cross_dir}/bin/${target}-nm"
cross_ranlib="${cross_dir}/bin/${target}-ranlib"
cross_readelf="${cross_dir}/bin/${target}-readelf"
cross_strip="${cross_dir}/bin/${target}-strip"
cross_strings="${cross_dir}/bin/${target}-strings"
cross_sysroot="${cross_dir}/${target}/sysroot"

for path in "${cross_gcc}" "${cross_gxx}" "${cross_ar}" "${cross_as}" \
	"${cross_ld}" "${cross_nm}" "${cross_ranlib}" "${cross_readelf}" \
	"${cross_strip}" "${cross_strings}"; do
	if [ ! -x "${path}" ]; then
		echo "Cross-toolchain executable is missing: ${path}" >&2
		exit 1
	fi
done

cross_libstdcxx=$("${cross_gxx}" -print-file-name=libstdc++.a)
if [ "${cross_libstdcxx}" = libstdc++.a ] ||
   [ ! -f "${cross_libstdcxx}" ]; then
	echo "The cross C++ runtime is missing: ${cross_libstdcxx}" >&2
	exit 1
fi

mkdir -p "${download_dir}" "${build_dir}"
printf '%s  %s\n' "${gcc_sha256}" "${download_dir}/${gcc_archive}" |
	sha256sum -c -
printf '%s  %s\n' "${binutils_sha256}" \
	"${download_dir}/${binutils_archive}" | sha256sum -c -
download "${zlib_url}" "${download_dir}/${zlib_archive}" "${zlib_sha256}"

source_dir="${build_dir}/src"
gcc_source="${source_dir}/gcc-${gcc_version}"
binutils_source="${source_dir}/binutils-${binutils_version}"
zlib_source="${source_dir}/zlib-${zlib_version}"
dependency_prefix="${build_dir}/target-dependencies"
staging_dir="${build_dir}/staging"
staged_prefix="${staging_dir}${native_prefix}"
native_sysroot="${staged_prefix}/sysroot"

rm -rf "${source_dir}" "${dependency_prefix}" "${staging_dir}" \
	"${build_dir}/gmp" "${build_dir}/mpfr" "${build_dir}/mpc" \
	"${build_dir}/zlib" "${build_dir}/binutils" "${build_dir}/gcc"
mkdir -p "${source_dir}" "${dependency_prefix}" "${native_sysroot}"
tar -xf "${download_dir}/${gcc_archive}" -C "${source_dir}"
tar -xf "${download_dir}/${binutils_archive}" -C "${source_dir}"
tar -xf "${download_dir}/${zlib_archive}" -C "${source_dir}"
(
	cd "${gcc_source}"
	./contrib/download_prerequisites --no-isl
)

cp -a "${cross_sysroot}/." "${native_sysroot}/"

# GCC's copies are newer than some prerequisite packages' config scripts and
# know the loongarch32 canonical triplet.
for package_source in "${gcc_source}/gmp" "${gcc_source}/mpfr" \
	"${gcc_source}/mpc" "${zlib_source}"; do
	for config_script in config.guess config.sub; do
		find -L "${package_source}" -name "${config_script}" -type f -print |
		while IFS= read -r destination; do
			cp "${gcc_source}/${config_script}" "${destination}"
		done
	done
done

build=$("${gcc_source}/config.guess")
target_cc="${cross_gcc} --sysroot=${native_sysroot}"
target_cxx="${cross_gxx} --sysroot=${native_sysroot}"
target_cppflags="-I${dependency_prefix}/include"
target_ldflags="-L${dependency_prefix}/lib"

mkdir -p "${build_dir}/gmp"
(
	cd "${build_dir}/gmp"
	CC="${target_cc}" AR="${cross_ar}" RANLIB="${cross_ranlib}" \
	CFLAGS="-Os -g0 -std=gnu17" ABI=standard \
	"${gcc_source}/gmp/configure" \
		--build="${build}" \
		--host="${target}" \
		--prefix="${dependency_prefix}" \
		--disable-assembly \
		--disable-shared \
		--enable-static
	make -j"${jobs}"
	make install
)

mkdir -p "${build_dir}/mpfr"
(
	cd "${build_dir}/mpfr"
	CC="${target_cc}" AR="${cross_ar}" RANLIB="${cross_ranlib}" \
	CPPFLAGS="${target_cppflags}" LDFLAGS="${target_ldflags}" \
	CFLAGS="-Os -g0" \
	"${gcc_source}/mpfr/configure" \
		--build="${build}" \
		--host="${target}" \
		--prefix="${dependency_prefix}" \
		--with-gmp="${dependency_prefix}" \
		--disable-shared \
		--enable-static
	make -j"${jobs}"
	make install
)

mkdir -p "${build_dir}/mpc"
(
	cd "${build_dir}/mpc"
	CC="${target_cc}" AR="${cross_ar}" RANLIB="${cross_ranlib}" \
	CPPFLAGS="${target_cppflags}" LDFLAGS="${target_ldflags}" \
	CFLAGS="-Os -g0" \
	"${gcc_source}/mpc/configure" \
		--build="${build}" \
		--host="${target}" \
		--prefix="${dependency_prefix}" \
		--with-gmp="${dependency_prefix}" \
		--with-mpfr="${dependency_prefix}" \
		--disable-shared \
		--enable-static
	make -j"${jobs}"
	make install
)

mkdir -p "${build_dir}/zlib"
(
	cd "${zlib_source}"
	CHOST="${target}" CC="${target_cc}" AR="${cross_ar}" \
	RANLIB="${cross_ranlib}" CFLAGS="-Os -g0" \
		./configure --prefix="${dependency_prefix}" --static
	make -j"${jobs}"
	make install
)

mkdir -p "${build_dir}/binutils"
(
	cd "${build_dir}/binutils"
	PATH="${cross_dir}/bin:${PATH}" \
	CC="${target_cc}" CXX="${target_cxx}" \
	AR="${cross_ar}" AS="${cross_as}" LD="${cross_ld}" \
	NM="${cross_nm}" RANLIB="${cross_ranlib}" \
	CPPFLAGS="${target_cppflags}" \
	CFLAGS="-Os -g0 ${target_cppflags}" \
	CXXFLAGS="-Os -g0 ${target_cppflags}" \
	LDFLAGS="${target_ldflags} -static-libstdc++ -static-libgcc" \
	"${binutils_source}/configure" \
		--build="${build}" \
		--host="${target}" \
		--target="${target}" \
		--prefix="${native_prefix}" \
		--with-sysroot="${native_prefix}/sysroot" \
		--with-system-zlib \
		--enable-64-bit-bfd \
		--disable-gdb \
		--disable-gdbserver \
		--disable-gprof \
		--disable-gprofng \
		--disable-nls \
		--disable-shared \
		--disable-sim \
		--disable-werror \
		--enable-static \
		--without-debuginfod \
		--without-zstd
	PATH="${cross_dir}/bin:${PATH}" make -j"${jobs}" \
		MAKEINFO=true tooldir="${native_prefix}"
	PATH="${cross_dir}/bin:${PATH}" make \
		MAKEINFO=true DESTDIR="${staging_dir}" \
		tooldir="${native_prefix}" install
)

mkdir -p "${build_dir}/gcc"
(
	cd "${build_dir}/gcc"
	PATH="${cross_dir}/bin:${PATH}" \
	CC="${target_cc}" CXX="${target_cxx}" \
	CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ \
	CC_FOR_TARGET="${target_cc}" CXX_FOR_TARGET="${target_cxx}" \
	AR="${cross_ar}" AS="${cross_as}" LD="${cross_ld}" \
	NM="${cross_nm}" RANLIB="${cross_ranlib}" \
	AR_FOR_TARGET="${cross_ar}" AS_FOR_TARGET="${cross_as}" \
	LD_FOR_TARGET="${cross_ld}" NM_FOR_TARGET="${cross_nm}" \
	RANLIB_FOR_TARGET="${cross_ranlib}" \
	CPPFLAGS="${target_cppflags}" \
	CFLAGS="-Os -g0 ${target_cppflags}" \
	CXXFLAGS="-Os -g0 ${target_cppflags}" \
	LDFLAGS="${target_ldflags}" \
	"${gcc_source}/configure" \
		--build="${build}" \
		--host="${target}" \
		--target="${target}" \
		--prefix="${native_prefix}" \
		--with-sysroot="${native_prefix}/sysroot" \
		--with-build-sysroot="${native_sysroot}" \
		--with-build-time-tools="${cross_dir}/${target}/bin" \
		--with-native-system-header-dir=/usr/include \
		--with-gmp="${dependency_prefix}" \
		--with-mpfr="${dependency_prefix}" \
		--with-mpc="${dependency_prefix}" \
		--with-system-zlib \
		--with-arch="${arch}" \
		--with-tune=loongarch32 \
		--with-abi="${abi}" \
		--with-stage1-ldflags="-static-libstdc++ -static-libgcc" \
		--enable-checking=release \
		--enable-languages=c \
		--enable-threads=posix \
		--disable-bootstrap \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libvtv \
		--disable-lto \
		--disable-multilib \
		--disable-nls \
		--disable-shared
	PATH="${cross_dir}/bin:${PATH}" make -j"${jobs}" all-gcc \
		CC_FOR_TARGET="${target_cc}" \
		AR_FOR_TARGET="${cross_ar}" AS_FOR_TARGET="${cross_as}" \
		LD_FOR_TARGET="${cross_ld}" NM_FOR_TARGET="${cross_nm}" \
		RANLIB_FOR_TARGET="${cross_ranlib}"
	PATH="${cross_dir}/bin:${PATH}" make install-gcc \
		DESTDIR="${staging_dir}"
	PATH="${cross_dir}/bin:${PATH}" make -j"${jobs}" all-target-libgcc \
		CC_FOR_TARGET="${target_cc}" \
		AR_FOR_TARGET="${cross_ar}" AS_FOR_TARGET="${cross_as}" \
		LD_FOR_TARGET="${cross_ld}" NM_FOR_TARGET="${cross_nm}" \
		RANLIB_FOR_TARGET="${cross_ranlib}"
	PATH="${cross_dir}/bin:${PATH}" make install-target-libgcc \
		DESTDIR="${staging_dir}"
)

# Keep the native development sysroot small enough for the board's fixed
# 108 MiB UBI partition.  Dynamic C development needs headers, CRT objects,
# linker scripts, libc_nonshared.a and the empty post-glibc-2.34 compatibility
# archives, but not static libc/libm, locale source data or target utilities.
runtime_libdir="${native_sysroot}/usr/lib32/sf"
for archive_file in "${runtime_libdir}"/*.a; do
	[ -f "${archive_file}" ] || continue
	archive_name=$(basename -- "${archive_file}")
	case "${archive_name}" in
		libc_nonshared.a|libpthread.a|libdl.a|librt.a|libutil.a)
			;;
		*)
			find "${archive_file}" -delete
			;;
	esac
done
rm -rf "${staged_prefix}/share/info" "${staged_prefix}/share/man" \
	"${staged_prefix}/share/locale" \
	"${staged_prefix}/lib/gcc/${target}/${gcc_version}/plugin" \
	"${native_sysroot}/sbin" "${native_sysroot}/usr/bin" \
	"${native_sysroot}/usr/libexec" "${native_sysroot}/usr/sbin" \
	"${native_sysroot}/usr/share" "${runtime_libdir}/gconv"

for program in addr2line ar as c++filt cpp gcc ld nm objcopy objdump ranlib \
	readelf size strings strip; do
	if [ ! -x "${staged_prefix}/bin/${program}" ]; then
		echo "Native tool was not installed: ${program}" >&2
		exit 1
	fi
done

find "${staged_prefix}/bin" "${staged_prefix}/libexec" \
	-type f -perm /111 -print |
while IFS= read -r candidate; do
	if file "${candidate}" | grep -q 'ELF 32-bit.*LoongArch'; then
		"${cross_strip}" --strip-unneeded "${candidate}"
		if ! "${cross_readelf}" -h "${candidate}" |
			grep -q 'Flags:.*0x41'; then
			echo "Native executable is not LA32R OBJ-v1: ${candidate}" >&2
			exit 1
		fi
		if "${cross_readelf}" -d "${candidate}" 2>/dev/null |
			grep -Eq \
				'NEEDED.*(libstdc\+\+|libgmp|libmpfr|libmpc|libz)'; then
			echo "Native tool has an unbundled build dependency: ${candidate}" >&2
			"${cross_readelf}" -d "${candidate}" >&2
			exit 1
		fi
		if "${cross_readelf}" -d "${candidate}" 2>/dev/null |
			grep -Eq 'RPATH|RUNPATH'; then
			echo "Native tool has an unexpected runtime path: ${candidate}" >&2
			"${cross_readelf}" -d "${candidate}" >&2
			exit 1
		fi
	elif file "${candidate}" | grep -q 'ELF '; then
		echo "Unexpected host executable in native toolchain: ${candidate}" >&2
		exit 1
	fi
done

for path in \
	"${staged_prefix}/bin/gcc" \
	"${staged_prefix}/bin/as" \
	"${staged_prefix}/bin/ld" \
	"${staged_prefix}/libexec/gcc/${target}/${gcc_version}/cc1"; do
	if ! "${cross_readelf}" -h "${path}" |
		grep -q 'Class:.*ELF32'; then
		echo "Native tool is not ELF32: ${path}" >&2
		exit 1
	fi
	if ! "${cross_readelf}" -h "${path}" |
		grep -q 'Machine:.*LoongArch'; then
		echo "Native tool is not LoongArch: ${path}" >&2
		exit 1
	fi
	if ! "${cross_readelf}" -h "${path}" |
		grep -q 'Flags:.*0x41'; then
		echo "Native tool is not LA32R OBJ-v1: ${path}" >&2
		exit 1
	fi
	if ! "${cross_readelf}" -l "${path}" |
		grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
		echo "Native tool uses an unexpected dynamic loader: ${path}" >&2
		exit 1
	fi
done

sanity_source="${build_dir}/hello.c"
sanity_binary="${build_dir}/hello"
printf '%s\n' \
	'#include <stdio.h>' \
	'int main(void) { puts("Hello from Gemmont"); return 0; }' \
	>"${sanity_source}"
"${cross_gcc}" --sysroot="${native_sysroot}" \
	-march="${arch}" -mabi="${abi}" \
	"${sanity_source}" -pthread -lm -o "${sanity_binary}"
if ! "${cross_readelf}" -h "${sanity_binary}" |
	grep -q 'Flags:.*0x41'; then
	echo "Packaged development sysroot did not produce LA32R OBJ-v1." >&2
	exit 1
fi
if ! "${cross_readelf}" -l "${sanity_binary}" |
	grep -q '/lib32/ld-linux-loongarch-ilp32s.so.1'; then
	echo "Packaged development sysroot selected an unexpected loader." >&2
	exit 1
fi

if ! "${cross_strings}" "${native_sysroot}/lib32/sf/libc.so.6" |
	grep -q 'stable release version 2.44'; then
	echo "Packaged development sysroot is not glibc ${glibc_version}." >&2
	exit 1
fi
if find "${staged_prefix}" \( -name 'libc-2.28.so' -o \
	-name 'libstdc++.so.6.0.25' \) -print -quit | grep -q .; then
	echo "Legacy Loongson Education runtime leaked into native toolchain." >&2
	exit 1
fi

rm -rf "${native_dir}"
mkdir -p "${native_dir}/rootfs/opt" "${native_dir}/licenses"
cp -a "${staged_prefix}" "${native_dir}/rootfs/opt/"
cp "${gcc_source}/COPYING3" "${native_dir}/licenses/gcc-COPYING3"
cp "${gcc_source}/COPYING.RUNTIME" \
	"${native_dir}/licenses/gcc-COPYING.RUNTIME"
cp "${binutils_source}/COPYING3" \
	"${native_dir}/licenses/binutils-COPYING3"
cp "${glibc_source}/COPYING.LIB" \
	"${native_dir}/licenses/glibc-COPYING.LIB"
cp "${linux_source}/COPYING" "${native_dir}/licenses/linux-COPYING"
cp "${linux_source}/LICENSES/exceptions/Linux-syscall-note" \
	"${native_dir}/licenses/linux-syscall-note"
cp "${zlib_source}/LICENSE" "${native_dir}/licenses/zlib-LICENSE"

{
	printf 'toolchain_revision=%s\n' "${toolchain_revision}"
	printf 'gcc_version=%s\n' "${gcc_version}"
	printf 'binutils_version=%s\n' "${binutils_version}"
	printf 'glibc_version=%s\n' "${glibc_version}"
	printf 'glibc_commit=%s\n' "${glibc_commit}"
	printf 'glibc_patch_sha256=%s\n' "${glibc_patch_sha256}"
	printf 'linux_headers_version=%s\n' "${linux_headers_version}"
	printf 'linux_source_commit=%s\n' "${linux_commit}"
	printf 'zlib_version=%s\n' "${zlib_version}"
	printf 'target=%s\n' "${target}"
	printf 'arch=%s\n' "${arch}"
	printf 'abi=%s\n' "${abi}"
	printf 'languages=c\n'
	printf 'prefix=%s\n' "${native_prefix}"
	printf 'sysroot=%s/sysroot\n' "${native_prefix}"
	printf 'libc=glibc-2.44-upstream-with-la32-fix\n'
	printf 'provenance=upstream-with-la32-fix\n'
	printf 'gcc_sha256=%s\n' "${gcc_sha256}"
	printf 'binutils_sha256=%s\n' "${binutils_sha256}"
	printf 'zlib_sha256=%s\n' "${zlib_sha256}"
} >"${native_dir}/native-toolchain.manifest"
cp "${native_dir}/native-toolchain.manifest" "${marker}"

echo "Built GCC ${gcc_version} LA32R native toolchain: ${native_dir}"
