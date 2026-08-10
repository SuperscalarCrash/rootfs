#!/bin/sh
set -eu

target_dir=${1:?missing Buildroot target directory}
inittab="${target_dir}/etc/inittab"
misc_fonts_dir="${target_dir}/usr/share/fonts/X11/misc"
font_encodings_dir="${target_dir}/usr/share/fonts/X11/encodings"
dejavu_fonts_dir="${target_dir}/usr/share/fonts/dejavu"

install -d -m 0700 "${target_dir}/root/.ssh"
install -d -m 0755 "${target_dir}/etc/ssh/sshd_config.d"
chmod 0600 "${target_dir}/root/.ssh/authorized_keys"
chmod 0600 "${target_dir}/etc/ssh/sshd_config"

if [ ! -f "${inittab}" ]; then
	echo "BusyBox inittab is missing from the target root filesystem" >&2
	exit 1
fi

# Buildroot creates the ttyS0 getty selected by the defconfig.  Add a second,
# independent getty for the framebuffer virtual terminal used by VGA and a
# PS/2 keyboard.  Replace any existing tty1 entry so repeated post-build
# invocations remain deterministic and never start competing getty processes.
sed -i \
	'/^# Gemmont framebuffer console$/d; /^tty1::/d' \
	"${inittab}"
cat >>"${inittab}" <<'EOF'

# Gemmont framebuffer console
tty1::respawn:/sbin/getty -L tty1 0 linux # GEMMONT_FRAMEBUFFER
EOF

if [ ! -x "${target_dir}/bin/bash" ]; then
	echo "Bash is missing from the target root filesystem" >&2
	exit 1
fi

root_shell=$(
	awk -F: '$1 == "root" { print $7 }' "${target_dir}/etc/passwd"
)
case "${root_shell}" in
	/bin/bash)
		;;
	/bin/sh)
		sed -i \
			's#^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)/bin/sh$#\1/bin/bash#' \
			"${target_dir}/etc/passwd"
		;;
	*)
		echo "Unexpected root login shell: ${root_shell}" >&2
		exit 1
		;;
esac

if [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]; then
	if [ ! -s "${SSH_AUTHORIZED_KEYS_FILE}" ]; then
		echo "SSH_AUTHORIZED_KEYS_FILE is not a readable, non-empty file: ${SSH_AUTHORIZED_KEYS_FILE}" >&2
		exit 1
	fi
	install -m 0600 "${SSH_AUTHORIZED_KEYS_FILE}" \
		"${target_dir}/root/.ssh/authorized_keys"
fi

if [ -n "${LINUX_RELEASE_ARCHIVE:-}" ]; then
	"$(dirname "$0")/../../../scripts/install-kernel-modules.sh" \
		"${LINUX_RELEASE_ARCHIVE}" "${target_dir}"
fi

# The flash layout provides 864 UBI erase blocks for the complete rootfs.  The
# X.Org's fallback package installs already-compressed copies of every fixed
# bitmap font for many legacy encodings even though this image uses C.UTF-8 and
# a Latin UI.  Keep the base and ISO-8859-1 fixed fonts used by Xterm, but omit
# the duplicate legacy encodings and large CJK glyph sets so the image remains
# within the fixed UBI partition.
find "${misc_fonts_dir}" -type f \
	\( \( -name '*-ISO8859-*.pcf.gz' ! -name '*-ISO8859-1.pcf.gz' \) \
	-o -name '*-KOI8-R.pcf.gz' -o -name '*-JISX0201.1976-0.pcf.gz' \) \
	-delete
for font in 12x13ja.pcf.gz 18x18ja.pcf.gz 18x18ko.pcf.gz k14.pcf.gz; do
	rm -f "${misc_fonts_dir}/${font}"
done
"${target_dir}/../host/bin/mkfontdir" "${misc_fonts_dir}"
rm -rf "${font_encodings_dir}/large"
(
	cd "${font_encodings_dir}"
	"${target_dir}/../host/bin/mkfontscale" -b -s -l -n -r \
		-p /usr/share/fonts/X11/encodings -e . .
)

# Fluxbox uses Xft for menus and window titles.  Retain the regular DejaVu Sans
# face as its scalable UI font, but remove the optional bold/oblique variants
# to preserve the limited UBI space.
find "${dejavu_fonts_dir}" -type f -name 'DejaVuSans-*.ttf' -delete
