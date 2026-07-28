################################################################################
#
# gemmont-native-toolchain
#
################################################################################

GEMMONT_NATIVE_TOOLCHAIN_VERSION = 16.1.0-r1
GEMMONT_NATIVE_TOOLCHAIN_SITE = $(BR2_EXTERNAL_GEMMONT_ROOTFS_PATH)/.toolchains/gcc-16.1.0-la32r-native
GEMMONT_NATIVE_TOOLCHAIN_SITE_METHOD = local
GEMMONT_NATIVE_TOOLCHAIN_LICENSE = \
	GPL-3.0+, \
	GPL-3.0-with-GCC-exception, \
	Zlib
GEMMONT_NATIVE_TOOLCHAIN_LICENSE_FILES = \
	licenses/gcc-COPYING3 \
	licenses/gcc-COPYING.RUNTIME \
	licenses/binutils-COPYING3 \
	licenses/zlib-LICENSE

GEMMONT_NATIVE_TOOLCHAIN_PREFIX = /opt/gemmont-gcc-16.1.0
GEMMONT_NATIVE_TOOLCHAIN_RELATIVE_PREFIX = ../../opt/gemmont-gcc-16.1.0
GEMMONT_NATIVE_TOOLCHAIN_PROGRAMS = \
	addr2line \
	ar \
	as \
	c++filt \
	cpp \
	gcc \
	ld \
	nm \
	objcopy \
	objdump \
	ranlib \
	readelf \
	size \
	strings \
	strip

define GEMMONT_NATIVE_TOOLCHAIN_INSTALL_TARGET_CMDS
	cp -a $(@D)/rootfs/. $(TARGET_DIR)/
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/usr/bin
	for program in $(GEMMONT_NATIVE_TOOLCHAIN_PROGRAMS); do \
		ln -snf \
			$(GEMMONT_NATIVE_TOOLCHAIN_RELATIVE_PREFIX)/bin/$${program} \
			$(TARGET_DIR)/usr/bin/$${program}; \
	done
	ln -snf $(GEMMONT_NATIVE_TOOLCHAIN_RELATIVE_PREFIX)/bin/gcc \
		$(TARGET_DIR)/usr/bin/cc
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/usr/share/gemmont-toolchain
	$(INSTALL) -m 0644 $(@D)/native-toolchain.manifest \
		$(TARGET_DIR)/usr/share/gemmont-toolchain/native-toolchain.manifest
	$(INSTALL) -d -m 0755 \
		$(TARGET_DIR)/usr/share/licenses/gemmont-native-toolchain
	cp -a $(@D)/licenses/. \
		$(TARGET_DIR)/usr/share/licenses/gemmont-native-toolchain/
endef

$(eval $(generic-package))
