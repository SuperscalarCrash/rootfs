.PHONY: all toolchain rootfs configure menuconfig savedefconfig check kernel \
	board-smoke-test clean

all: rootfs

toolchain:
	./scripts/build-gcc16-toolchain.sh

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
