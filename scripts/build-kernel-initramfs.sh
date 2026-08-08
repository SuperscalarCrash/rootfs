#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${root_dir}/output"}
linux_dir=${LINUX_DIR:-"${root_dir}/../linux"}
kernel_output_dir=${KERNEL_OUTPUT_DIR:-"${root_dir}/.build/linux-initramfs"}
kernel_artifact_dir=${KERNEL_ARTIFACT_DIR:-"${root_dir}/artifacts/kernel"}
cross_compile=${CROSS_COMPILE:-loongarch32-linux-gnusf-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}
cpu_hz=${CPU_HZ:-}
kernel_localversion=${KERNEL_LOCALVERSION:-}
initramfs="${output_dir}/images/rootfs.cpio.gz"

case "${cpu_hz}" in
	''|*[!0-9]*|0)
		echo "Set CPU_HZ to the FPGA CPU clock in Hz." >&2
		exit 2
		;;
esac

if [ ! -s "${initramfs}" ]; then
	echo "${initramfs} is missing; run scripts/build.sh first." >&2
	exit 1
fi

if ! command -v "${cross_compile}gcc" >/dev/null 2>&1; then
	default_toolchain="${root_dir}/.toolchains/gcc-16.1.0-la32r/bin"
	if [ -x "${default_toolchain}/${cross_compile}gcc" ]; then
		PATH="${default_toolchain}:${PATH}"
		export PATH
	else
		echo "Cannot find ${cross_compile}gcc" >&2
		exit 1
	fi
fi

mkdir -p "${kernel_output_dir}" "${kernel_artifact_dir}"

make -C "${linux_dir}" O="${kernel_output_dir}" ARCH=loongarch \
	CROSS_COMPILE="${cross_compile}" LOCALVERSION= chiplab_la32r_defconfig

"${linux_dir}/scripts/config" --file "${kernel_output_dir}/.config" \
	--set-str INITRAMFS_SOURCE "${initramfs}" \
	--set-str CMDLINE \
	"console=tty0 console=ttyS0,115200 earlycon=uart8250,mmio,0x1fe001e0,115200 rdinit=/init cpuclock=${cpu_hz}"
if [ -n "${kernel_localversion}" ]; then
	"${linux_dir}/scripts/config" --file "${kernel_output_dir}/.config" \
		--set-str LOCALVERSION "${kernel_localversion}" \
		--disable LOCALVERSION_AUTO
fi

make -C "${linux_dir}" O="${kernel_output_dir}" ARCH=loongarch \
	CROSS_COMPILE="${cross_compile}" LOCALVERSION= olddefconfig
# kernelrelease reads include/config/auto.conf when an output tree has already
# been built.  Refresh it now so a changed LOCALVERSION is not masked by the
# previous build's cached release string.
make -C "${linux_dir}" O="${kernel_output_dir}" ARCH=loongarch \
	CROSS_COMPILE="${cross_compile}" LOCALVERSION= syncconfig

kernel_release=$(
	make -s -C "${linux_dir}" O="${kernel_output_dir}" ARCH=loongarch \
		CROSS_COMPILE="${cross_compile}" LOCALVERSION= kernelrelease
)
if [ -d "${output_dir}/target/lib/modules" ] &&
   find "${output_dir}/target/lib/modules" -mindepth 1 -maxdepth 1 \
	-type d -print -quit | grep -q . &&
   [ ! -d "${output_dir}/target/lib/modules/${kernel_release}" ]; then
	echo "Rootfs modules do not match kernel release ${kernel_release}" >&2
	find "${output_dir}/target/lib/modules" -mindepth 1 -maxdepth 1 \
		-type d -printf 'Found module release: %f\n' >&2
	exit 1
fi

make -C "${linux_dir}" O="${kernel_output_dir}" ARCH=loongarch \
	CROSS_COMPILE="${cross_compile}" LOCALVERSION= \
	-j"${jobs}" vmlinux dtbs modules

install -m 0644 "${kernel_output_dir}/vmlinux" \
	"${kernel_artifact_dir}/vmlinux"
install -m 0644 \
	"${kernel_output_dir}/arch/loongarch/boot/dts/loongson-chiplab.dtb" \
	"${kernel_artifact_dir}/loongson-chiplab.dtb"
install -m 0644 "${kernel_output_dir}/.config" \
	"${kernel_artifact_dir}/kernel.config"

(
	cd "${kernel_artifact_dir}"
	sha256sum vmlinux loongson-chiplab.dtb kernel.config > SHA256SUMS
)

echo "Kernel with embedded Buildroot initramfs: ${kernel_artifact_dir}/vmlinux"
