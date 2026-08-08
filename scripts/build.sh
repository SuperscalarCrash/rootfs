#!/bin/sh
set -eu

# Do not let an unrelated cross-toolchain inherited from the login shell
# participate in Buildroot host or target configure probes.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${root_dir}/output"}
download_dir=${DL_DIR:-"${root_dir}/dl"}
toolchain_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-16.1.0-la32r"}
native_toolchain_dir=${GCC16_NATIVE_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-16.1.0-la32r-native"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}
command=${1:-all}

if [ "${jobs}" -gt 4 ]; then
	jobs=4
fi

buildroot_dir=$("${root_dir}/scripts/prepare-buildroot.sh")
make_args="-C ${buildroot_dir} O=${output_dir} BR2_EXTERNAL=${root_dir} BR2_DL_DIR=${download_dir} BR2_TOOLCHAIN_EXTERNAL_PATH=${toolchain_dir} GEMMONT_NATIVE_TOOLCHAIN_SITE=${native_toolchain_dir} BR2_JLEVEL=${jobs}"

configure()
{
	# shellcheck disable=SC2086
	make ${make_args} gemmont_chiplab_la32r_defconfig
}

case "${command}" in
	configure)
		configure
		;;
	menuconfig)
		configure
		# shellcheck disable=SC2086
		make ${make_args} menuconfig
		;;
	savedefconfig)
		# shellcheck disable=SC2086
		make ${make_args} savedefconfig \
			BR2_DEFCONFIG="${root_dir}/configs/gemmont_chiplab_la32r_defconfig"
		;;
	clean)
		# shellcheck disable=SC2086
		make ${make_args} clean
		;;
	all)
		mkdir -p "${download_dir}"
		DL_DIR="${download_dir}" GCC16_TOOLCHAIN_DIR="${toolchain_dir}" \
			"${root_dir}/scripts/build-gcc16-toolchain.sh"
		DL_DIR="${download_dir}" GCC16_TOOLCHAIN_DIR="${toolchain_dir}" \
			GCC16_NATIVE_TOOLCHAIN_DIR="${native_toolchain_dir}" \
			"${root_dir}/scripts/build-gcc16-native-toolchain.sh"
		configure
		# shellcheck disable=SC2086
		make ${make_args} -j"${jobs}"
		"${root_dir}/scripts/check-rootfs.sh"
		"${root_dir}/scripts/package-artifacts.sh"
		;;
	*)
		echo "Usage: $0 [all|configure|menuconfig|savedefconfig|clean]" >&2
		exit 2
		;;
esac
