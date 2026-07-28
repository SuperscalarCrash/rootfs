.PHONY: all toolchain cross-toolchain native-toolchain rootfs configure \
	menuconfig savedefconfig check kernel board-smoke-test clean

all: rootfs

toolchain: native-toolchain

cross-toolchain:
	./scripts/build-gcc16-toolchain.sh

native-toolchain: cross-toolchain
	./scripts/build-gcc16-native-toolchain.sh

rootfs:
	./scripts/build.sh

configure:
	./scripts/build.sh configure

menuconfig:
	./scripts/build.sh menuconfig

savedefconfig:
	./scripts/build.sh savedefconfig

check:
	./scripts/check-rootfs.sh

kernel:
	./scripts/build-kernel-initramfs.sh

board-smoke-test:
	./scripts/board-smoke-test.sh

clean:
	./scripts/build.sh clean
