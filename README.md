# Gemmont Chiplab LA32R rootfs

这个仓库使用 Buildroot 构建可在 Gemmont Chiplab FPGA 板上运行的
LA32R（ILP32S、soft-float）根文件系统。Buildroot 以固定版本的 Git
submodule 保存，板级配置、少量 LA32R 补丁、rootfs overlay 和构建脚本
保存在本仓库中；下载文件、编译目录和产物不提交到 Git。

当前 rootfs 包含：

- BusyBox init、串口 shell 和常用命令；
- OpenSSH 客户端、服务端、SFTP 和密钥工具；
- `iproute2`、`ethtool`、OpenSSL 和 CA 证书；
- 面向 Chiplab NAND 的只读检查工具以及 UBI/UBIFS 管理工具；
- initramfs、tar.zst、UBIFS 和 UBI 四种输出格式。

## GCC 16 用户态工具链

rootfs 由仓库脚本从 GNU 官方源码构建的 GCC 16.1.0 和 Binutils 2.46.1
编译，目标三元组为 `loongarch32-linux-gnusf`，固定使用
`-march=la32rv1.0 -mabi=ilp32s`。构建结果是 Gemmont 所需的 ELF32、
LA32R、ILP32S、soft-float、OBJ-v1 程序，并不是 LA32 或 LA64 程序。

上游 glibc 尚没有可直接替换的完整 LA32R 用户态 port。因此工具链只从
Loongson Education 的旧工具链中提取并校验 glibc 2.28 sysroot（libc、
动态加载器和 Linux UAPI 头文件）；GCC、汇编器、链接器、libgcc 以及
BusyBox/OpenSSH 等 rootfs 软件均由 GCC 16.1.0/新 Binutils 构建。旧
GCC 8 可执行文件不会进入新工具链，也不会参与 rootfs 编译。
工具链给 GCC 16 补充旧 glibc 头文件所需的
`__loongarch32r`/`_ABILP32` 兼容预处理宏；这些宏不改变指令集，也不会
给 Gemmont 增加非 LA32R 指令。

上游 Buildroot 目前只提供 LA64 目标。本仓库固定 Buildroot 2026.05.1，
并在临时 worktree 中应用
`patches/buildroot/0001-arch-add-la32r-external-toolchain-support.patch`。
submodule 本身保持干净，补丁增加 LA32R/ILP32S 和外部 GCC 16 版本
描述；GCC 16 由本仓库单独构建后作为预安装外部工具链交给 Buildroot。

## 构建

主机需要常见的 GCC/Buildroot 依赖，包括 GCC/G++、make、bison、flex、
git、curl、cpio、rsync、bc、file、tar、zstd 和 ncurses 开发包。GCC
所需的 GMP/MPFR/MPC 源码由 GCC 自带脚本下载并用上游 SHA-512 校验。

```sh
git submodule update --init
make
```

默认路径：

- GCC 16 工具链：`.toolchains/gcc-16.1.0-la32r/`
- Buildroot 输出：`output/`
- 下载缓存：`dl/`
- 可发布产物：`artifacts/`
- 打过补丁的临时 Buildroot worktree：`.build/buildroot/`

可通过环境变量覆盖并行度和输出路径：

```sh
JOBS=4 \
GCC16_TOOLCHAIN_DIR=/tmp/gemmont-gcc16 \
OUTPUT_DIR=/tmp/gemmont-rootfs-output \
make
```

也可只构建或验证工具链：

```sh
make toolchain
```

脚本会校验 GCC、Binutils 和 sysroot 三个下载文件的 SHA-256。已有且
通过版本、目标三元组和链接测试的 GCC 16 工具链会直接复用。

将 SSH 公钥写入镜像：

```sh
SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub" make
```

若已有同版本 Linux 发布包，可把其中的已签名模块一并装入 rootfs：

```sh
LINUX_RELEASE_ARCHIVE=../linux-7.1.4-SuperscalarCrach-la32r-v0.1.1-loongarch32.tar.zst \
SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub" make
```

脚本会拒绝含有多个模块版本或不安全路径的归档。生成嵌入式内核时应让
`KERNEL_LOCALVERSION` 与模块目录严格一致，例如：

```sh
CPU_HZ=72000000 \
KERNEL_LOCALVERSION=-SuperscalarCrach-la32r-v0.1.1 \
make kernel
```

镜像默认禁止 SSH 密码登录和空密码登录，只允许公钥登录。串口控制台
仍允许 root 登录，便于首次板级调试。首次启动时 OpenSSH 会在板上生成
唯一的 host key；不要把固定 host key 放进公开镜像。

常用维护目标：

```sh
make menuconfig
make savedefconfig
make check
make clean
```

`make savedefconfig` 会更新
`configs/gemmont_chiplab_la32r_defconfig`，提交前应重新执行 `make` 和
`make check`。

## 输出镜像

构建成功后 `artifacts/` 包含：

- `rootfs.cpio.gz`：嵌入 Linux 的 initramfs；
- `rootfs.tar.zst`：完整根文件系统归档；
- `rootfs.ubifs`：UBIFS 文件系统；
- `rootfs.ubi`：适配 128 KiB PEB、2 KiB page、512-byte subpage 的
  UBI 镜像；
- `buildroot.config`、`toolchain.manifest` 和 `SHA256SUMS`。

UBI 参数与 Linux Chiplab DTS 中的 108 MiB `ubi` 分区一致：
`PEB=0x20000`、`min I/O=0x800`、`LEB=0x1f800`、最大 864 个 LEB。

## GitHub Release

推送任意符合 `v*`（以 `v` 开头且后面非空）的 tag 时，
`.github/workflows/release.yml` 会：

1. 从源码构建并验证 GCC 16.1.0/Binutils 2.46.1；
2. 按源码和脚本哈希缓存完整 LA32R 工具链，后续 tag 可直接复用；
3. 用该工具链构建并检查全部 rootfs 镜像；
4. 上传 90 天保留的 Actions artifact，并创建或更新同名 GitHub
   Release。

Release 同时提供各格式镜像、构建配置、工具链清单、校验和，以及
`gemmont-rootfs-<tag>-loongarch32.tar.zst` 汇总归档。GCC 缓存只用于
加速 CI，不作为 Release 资产发布。

## 构建带 initramfs 的 Linux

先构建 rootfs，再给出当前 FPGA 的实际 CPU 时钟：

```sh
make
CPU_HZ=72000000 make kernel
```

脚本默认使用 `../linux`、`chiplab_la32r_defconfig` 和
`$HOME/.local/toolchains/gcc-16.1.0-loongarch`。它不会把频率写回 DTS
或内核源码，而只写入该次输出目录的内核命令行。可用
`LINUX_DIR`、`KERNEL_OUTPUT_DIR`、`CROSS_COMPILE` 覆盖这些路径。

生成的自包含内核位于 `artifacts/kernel/vmlinux`。串口参数为
115200 8N1；Buildroot 完成启动脚本后会输出：

```text
GEMMONT_ROOTFS_READY
```

## 上板与冒烟测试

发布包中的原始 `vmlinux` 没有 initramfs，单独启动时会因为找不到
`/init` 而 panic；测试完整 rootfs 时，应通过 `make kernel` 生成
`artifacts/kernel/vmlinux`，再由 U-Boot TFTP 加载：

```text
setenv ipaddr 172.25.2.194
setenv serverip 172.25.2.193
tftpboot 0xa3000000 vmlinux
bootelf 0xa3000000 bootcmd
```

获得 DHCP 地址后，可以通过连接板机网络的跳板机执行只读冒烟测试：

```sh
BOARD_ADDRESS=172.25.2.56 JUMP_HOST=fpgadev make board-smoke-test
```

脚本验证版本签名、BusyBox、OpenSSH、网络、内核模块和 MTD 信息，不会
attach、擦除或写入 NAND。v0.2.6 FPGA 与 v0.1.1 Linux 的实测记录和当前
已知限制见
[`docs/board-test-v0.2.6-v0.1.1.md`](docs/board-test-v0.2.6-v0.1.1.md)。

## NAND 使用边界

镜像不会在启动时自动 attach、格式化或写入 NAND。`gemmont-mount-ubi`
只会挂载已经存在的 `rootfs` volume；找不到 volume 时会退出，不会创建
或格式化它。

首次使用未知 NAND 前，应先通过 `nanddump` 备份并离板保存校验和。
确认 `mtd0` 是只读 `kernel`、`mtd1` 是可写 `ubi` 后，才能对
`/dev/mtd1` 执行 `ubiformat`。不要对整片 NAND 或 `kernel` 分区执行
擦除、`nandwrite` 或格式化。rootfs 刻意不安装 raw `nandwrite`、
`flash_erase` 和 `mtd_debug`，但保留显式的 UBI provisioning 工具。

## 仓库结构

```text
buildroot/                      固定版本的上游 Buildroot submodule
configs/                        Buildroot defconfig
board/gemmont/chiplab/          overlay 和 post-build 脚本
patches/buildroot/              可审计的 LA32R Buildroot 补丁
scripts/                        下载、构建、检查、打包和内核集成脚本
```
