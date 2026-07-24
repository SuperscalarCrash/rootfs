#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
download_dir=${DL_DIR:-"${root_dir}/dl"}
archive=loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0.tar.xz
url="https://gitee.com/loongson-edu/la32r-toolchains/releases/download/v0.0.3/${archive}"
expected_sha256=64856b06a2793863aa60104ef91ad04c7ba99c0de57928ceab7d31dd884ce647
package_dir="${download_dir}/toolchain-external-custom"
destination="${package_dir}/${archive}"

mkdir -p "${package_dir}"

if [ -f "${destination}" ] &&
   printf '%s  %s\n' "${expected_sha256}" "${destination}" |
	sha256sum -c - >/dev/null 2>&1; then
	echo "Using verified LA32R toolchain archive: ${destination}"
	exit 0
fi

rm -f "${destination}.tmp"
curl -fL --retry 3 --output "${destination}.tmp" "${url}"

printf '%s  %s\n' "${expected_sha256}" "${destination}.tmp" |
	sha256sum -c -
mv "${destination}.tmp" "${destination}"

echo "Downloaded and verified LA32R toolchain archive: ${destination}"

