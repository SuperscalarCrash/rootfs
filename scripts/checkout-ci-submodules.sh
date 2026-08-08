#!/bin/sh
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
glibc_git_url=${GLIBC_GIT_URL:-git://sourceware.org/git/glibc.git}

# Sourceware's HTTPS endpoint can rate-limit shared GitHub-hosted runner IPs.
# Keep the canonical HTTPS URL in .gitmodules, but use Sourceware's own
# read-only Git service in CI.  The superproject gitlinks below still pin and
# verify the exact Buildroot and glibc commits.
git -C "${root_dir}" submodule sync -- buildroot
git -C "${root_dir}" submodule update --init --depth=1 buildroot
git -C "${root_dir}" \
	-c "submodule.glibc.url=${glibc_git_url}" \
	submodule update --init --depth=1 glibc

for submodule in buildroot glibc; do
	expected=$(git -C "${root_dir}" rev-parse "HEAD:${submodule}")
	actual=$(git -C "${root_dir}/${submodule}" rev-parse HEAD)
	if [ "${actual}" != "${expected}" ]; then
		echo "${submodule} checkout mismatch: ${actual} != ${expected}" >&2
		exit 1
	fi
	printf '%s=%s\n' "${submodule}" "${actual}"
done
