#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${OUTPUT_DIR:-"${root_dir}/output"}
artifact_dir=${ARTIFACT_DIR:-"${root_dir}/artifacts"}
images_dir="${output_dir}/images"
toolchain_dir=${GCC16_TOOLCHAIN_DIR:-"${root_dir}/.toolchains/gcc-16.1.0-la32r"}

mkdir -p "${artifact_dir}"

for image in rootfs.cpio.gz rootfs.tar.zst rootfs.ubifs rootfs.ubi; do
	install -m 0644 "${images_dir}/${image}" "${artifact_dir}/${image}"
done

install -m 0644 "${output_dir}/.config" "${artifact_dir}/buildroot.config"
install -m 0644 \
	"${toolchain_dir}/share/gemmont-toolchain.manifest" \
	"${artifact_dir}/toolchain.manifest"

(
	cd "${artifact_dir}"
	sha256sum rootfs.cpio.gz rootfs.tar.zst rootfs.ubifs rootfs.ubi \
		buildroot.config toolchain.manifest > SHA256SUMS
)

echo "Artifacts written to ${artifact_dir}"
