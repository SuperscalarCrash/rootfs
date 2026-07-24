#!/bin/sh
set -eu

archive=${1:?missing Linux release archive}
target_dir=${2:?missing Buildroot target directory}

if [ ! -s "${archive}" ]; then
	echo "Linux release archive is missing or empty: ${archive}" >&2
	exit 1
fi

module_roots=$(
	tar --zstd -tf "${archive}" |
		sed -n 's#^\([^/][^/]*/lib/modules/[^/][^/]*\)/.*#\1#p' |
		sort -u
)
module_root_count=$(printf '%s\n' "${module_roots}" | sed '/^$/d' | wc -l)
if [ "${module_root_count}" -ne 1 ]; then
	echo "Expected one lib/modules tree in ${archive}, found ${module_root_count}" >&2
	exit 1
fi

module_root=${module_roots}
case "${module_root}" in
	*..*|/*)
		echo "Unsafe module path in ${archive}: ${module_root}" >&2
		exit 1
		;;
esac

top_dir=${module_root%%/*}
kernel_release=${module_root##*/}
tar --zstd -xf "${archive}" -C "${target_dir}" --strip-components=1 \
	"${top_dir}/lib/modules/${kernel_release}"

if ! find "${target_dir}/lib/modules/${kernel_release}" \
	-type f -name '*.ko' -print -quit | grep -q .; then
	echo "No kernel modules were installed from ${archive}" >&2
	exit 1
fi

echo "Installed Linux ${kernel_release} modules into the root filesystem"
