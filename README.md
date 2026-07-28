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
- 可在板上直接运行的 GCC 16.1.0、Binutils 2.46.1、C 头文件和链接库；
- initramfs、tar.zst、UBIFS 和 UBI 四种输出格式。

## GCC 16 用户态工具链

仓库会从未经修改的 GNU GCC 16.1.0 和 Binutils 2.46.1 源码构建两套
工具：

1. 在构建主机运行的 C/C++ 交叉工具链，用于构建 rootfs，并继续
   交叉构建下一套工具链；
2. 在 Gemmont LA32R Linux 上运行的原生 C 编译器和 Binutils，用于
   在板上现场执行 `gcc hello.c -o hello`。

两者的目标三元组都是 `loongarch32-linux-gnusf`，固定使用
`-march=la32rv1.0 -mabi=ilp32s`。产物是 Gemmont 所需的 ELF32、
LA32R、ILP32S、soft-float、OBJ-v1 程序，并不是 LA32 或 LA64 程序。
这里不需要修改 GCC 的 LA32R 后端；GCC 16 已有上游支持。仓库脚本负责
补齐目标 libc/sysroot、构建次序、安装布局和 ABI 校验。

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

板上工具链自包含安装在 `/opt/gemmont-gcc-16.1.0`。它自己的
`sysroot/` 保存 C 头文件、`crt*.o`、libc 链接文件和 `libgcc.a`，
避免 Buildroot 在生成生产 rootfs 时清除开发文件。`/usr/bin/gcc`、
`/usr/bin/cc`、`/usr/bin/as`、`/usr/bin/ld` 等链接让工具可以直接
使用。全部四种 rootfs 镜像都包含完整工具链；若后续改用 NFS root，
可直接把 `rootfs.tar.zst` 解包到 NFS 导出目录。

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
- 板上原生 GCC 16 payload：`.toolchains/gcc-16.1.0-la32r-native/`
- Buildroot 输出：`output/`
- 下载缓存：`dl/`
- 可发布产物：`artifacts/`
- 打过补丁的临时 Buildroot worktree：`.build/buildroot/`

可通过环境变量覆盖并行度和输出路径：

```sh
JOBS=4 \
GCC16_TOOLCHAIN_DIR=/tmp/gemmont-gcc16 \
GCC16_NATIVE_TOOLCHAIN_DIR=/tmp/gemmont-gcc16-native \
OUTPUT_DIR=/tmp/gemmont-rootfs-output \
make
```

也可分步构建或验证工具链：

```sh
make cross-toolchain   # 构建主机上运行的 LA32R 交叉工具链
make native-toolchain  # 交叉构建板上运行的 GCC；会先确保前者存在
make toolchain         # 等价于 make native-toolchain
```

脚本会校验 GCC、Binutils、zlib 和 sysroot 下载文件的 SHA-256。已有且
通过版本、目标三元组、ELF ABI 和链接测试的工具链会直接复用。原生
GCC 只启用 C 前端；主机交叉 GCC 同时启用 C 和 C++，因为 GCC 本身由
C++ 编写，交叉构建原生编译器时需要它。

## 板上现场编译

启动新 rootfs 后，不需要设置额外环境变量：

```sh
gcc --version
gcc -dumpmachine

cat > hello.c <<'EOF'
#include <stdio.h>

int main(void)
{
    puts("Hello from Gemmont GCC 16!");
    return 0;
}
EOF

gcc -O0 -Wall -Wextra -Werror hello.c -o hello
./hello
```

预期 `gcc -dumpmachine` 输出 `loongarch32-linux-gnusf`，程序输出
`Hello from Gemmont GCC 16!`。仓库的 `make board-smoke-test` 会通过
SSH 在板上自动完成同一项编译、执行和 ELF ABI 检查。

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
- `rootfs.ubi`：适配 128 KiB PEB、2 KiB page、2 KiB subpage 的
  UBI 镜像；
- `buildroot.config`、`toolchain.manifest`、
  `native-toolchain.manifest` 和 `SHA256SUMS`。

UBI 参数与 Linux Chiplab DTS 中的 108 MiB `ubi` 分区一致：
`PEB=0x20000`、`min I/O=0x800`、`LEB=0x1f000`、最大 864 个 LEB。
Chiplab NAND 驱动设置了 `NAND_NO_SUBPAGE_WRITE`，因此 UBI subpage
必须与 2 KiB NAND page 一致。

## GitHub Release

推送任意符合 `v*`（以 `v` 开头且后面非空）的 tag 时，
`.github/workflows/release.yml` 会：

1. 从源码构建并验证 GCC 16.1.0/Binutils 2.46.1 交叉及原生工具链；
2. 按源码和脚本哈希分别缓存两套 LA32R 工具链，后续 tag 可直接复用；
3. 用该工具链构建并检查全部 rootfs 镜像；
4. 上传 90 天保留的 Actions artifact，并创建或更新同名 GitHub
   Release。

Release 同时提供各格式镜像、构建配置、工具链清单、校验和，以及
`gemmont-rootfs-<tag>-loongarch32.tar.zst` 汇总归档。GCC 缓存只用于
加速 CI，不作为 Release 资产发布。
