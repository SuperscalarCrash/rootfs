#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
submodule_dir="${root_dir}/buildroot"
source_dir=${BUILDROOT_SOURCE_DIR:-"${root_dir}/.build/buildroot"}
patch_dir="${root_dir}/patches/buildroot"

if ! git -C "${submodule_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "Initializing Buildroot submodule" >&2
	git -C "${root_dir}" submodule update --init --recursive buildroot
fi

buildroot_commit=$(git -C "${submodule_dir}" rev-parse HEAD)

if [ ! -d "${source_dir}/.git" ] && \
   ! git -C "${source_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	mkdir -p "$(dirname -- "${source_dir}")"
	git -C "${submodule_dir}" worktree prune
	echo "Creating patched Buildroot worktree at ${source_dir}" >&2
	git -C "${submodule_dir}" worktree add --detach "${source_dir}" "${buildroot_commit}" >&2
fi

if [ "$(git -C "${source_dir}" rev-parse HEAD)" != "${buildroot_commit}" ]; then
	echo "Buildroot worktree does not match the pinned submodule commit." >&2
	echo "Remove ${source_dir} and run this script again." >&2
	exit 1
fi

for patch in "${patch_dir}"/*.patch; do
	[ -e "${patch}" ] || continue
	if git -C "${source_dir}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
		continue
	fi
	git -C "${source_dir}" apply --check "${patch}"
	echo "Applying $(basename -- "${patch}")" >&2
	git -C "${source_dir}" apply "${patch}"
done

printf '%s\n' "${source_dir}"

