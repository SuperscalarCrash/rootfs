# Gemmont Chiplab LA32R rootfs

这个仓库使用 Buildroot 构建可在 Gemmont Chiplab FPGA 板上运行的
LA32R（ILP32S、soft-float）根文件系统。Buildroot 以固定版本的 Git
submodule 保存，板级配置、少量 LA32R 补丁、rootfs overlay 和构建脚本
保存在本仓库中；下载文件、编译目录和产物不提交到 Git。

当前 rootfs 包含：

- BusyBox init、常用命令，以及作为串口和 SSH 登录 shell 的 Bash
  5.2.37；
- 面向串口展示的 Fastfetch 2.66.0；
- OpenSSH 客户端、服务端、SFTP 和密钥工具；
- GNU grep、tree、htop 3.5.1、tmux 3.6b 和带语法运行库的 Vim 9.1；
- lrzsz 的 `rz`/`sz`，以及 Android Debug Bridge 的 `adb` 客户端和
  `adbd` 守护程序；
- nginx 1.30.4（HTTP、HTTPS 和 HTTP/2）、NTP/ntpdate、ISC dhclient
  以及 iputils；
- Python 3.14.7，包含 SSL、readline、bz2、xz 和 zlib 支持；其
  `ctypes` 使用上游 libffi 3.7.1 的 `LOONGARCH32`/`FFI_ILP32S` 端口；
- `iproute2`、`ethtool`、OpenSSL 和 CA 证书；
- `evtest`，用于检查 PS/2 键盘等 Linux input 设备的事件；
- 面向 Chiplab NAND 的只读检查工具以及 UBI/UBIFS 管理工具；
- 可在板上直接运行的 GCC 16.1.0、Binutils 2.46.1、C 头文件和链接库；
- 可现场编译的 Hello World、VGA 和 NT35510 LCD 色条示例源码；
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

glibc 2.44 已在上游提供 LA32R/ILP32S port。本仓库以固定到
`glibc-2.44` 标签的 submodule 保存其源码，并使用相邻项目的
`../linux` 内核树安装 Linux UAPI 头文件。这个内核树当前为 7.1.4，
包含 Gemmont LA32R/Chiplab 所需的项目补丁；工具链不会下载另一份
Linux 源码。构建时在临时源码副本中应用
`patches/glibc/0001-loongarch-fix-pointer-mangling-for-la32.patch`，修正
2.44 中错误使用 LA64 `rotri.d` 的汇编指针混淆代码，并按 LA32R 手册
用移位与 OR 实现精简指令集中不存在的 rotate；submodule 本身仍严格
固定在原始发行标签且保持干净。glibc、动态加载器、libgcc、
libstdc++ 和 libatomic 均由
上游源码重新构建，不再提取或链接 Loongson Education 的 glibc 2.28、
Linux 5.14 UAPI 或 GCC 8 运行库。

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

系统保留 `/bin/sh` 指向 BusyBox ash，供启动脚本使用；root 用户通过
串口、VGA 本地终端或 SSH 登录时默认进入 `/bin/bash`。Buildroot 生成
的 `ttyS0` getty 保持不变，post-build 另外在 `tty1` 启动 getty；配合
包含 VGA framebuffer console、PS/2 控制器和 input/AT keyboard 驱动的
bitstream 与 Linux，显示器会出现登录提示，键盘可直接输入。登录后可
直接运行：

```sh
fastfetch
bash --version
htop --version
tmux -V
vim --version
adb version
nginx -v
ntpdate -q ntp.example.org
dhclient --version
ping -c 3 172.25.2.193
python3 --version
evtest
```

tmux 所需的 `C.UTF-8` locale 会随 rootfs 一并生成。`adb` 用于从板子
连接其他 ADB 目标；`adbd` 用于让主机连接板子。启用 `adbd` 只提供用户态
守护程序，USB ADB 还要求内核 USB gadget、UDC 和 FunctionFS 已正确配置；
没有这些板级条件时不自动启动 `adbd`，SSH 仍是默认远程管理通道。

`evtest` 会列出已注册的 input 设备，也可指定设备，例如
`evtest /dev/input/event0`。设备编号不固定，应按输出中的键盘名称选择；
未插键盘时没有按键事件是正常的，不影响 `ttyS0` 和 SSH 登录。

Fastfetch 保留 OS、内核、运行时间、CPU、内存、磁盘和网络等适合板级
展示的信息，关闭 Vulkan、Wayland、X11、DRM、多媒体和脚本语言等板上
无用的集成，默认不执行包管理器统计。

## 构建

主机需要常见的 GCC/Buildroot 依赖，包括 GCC/G++、make、bison、flex、
git、curl、cpio、rsync、bc、file、tar、zstd 和 ncurses 开发包。GCC
所需的 GMP/MPFR/MPC 源码由 GCC 自带脚本下载并用上游 SHA-512 校验。

```sh
git submodule update --init
make
```

`linux` 项目必须与本仓库并列放置为 `../linux`，且默认要求版本为
7.1.4；也可用 `LINUX_SOURCE_DIR=/绝对路径/linux` 显式指定。构建只会从
该树执行 `headers_install`，不会另行下载 Linux 源码。

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

脚本会校验 GCC、Binutils 和 zlib 下载文件的 SHA-256，并验证 glibc
submodule 与本地 Linux 源码版本。已有且
通过版本、目标三元组、ELF ABI 和链接测试的工具链会直接复用。原生
GCC 只启用 C 前端；主机交叉 GCC 同时启用 C 和 C++，因为 GCC 本身由
C++ 编写，交叉构建原生编译器时需要它。

板载 UBI 分区固定为 108 MiB。为在保留原生 GCC 的同时容纳完整 rootfs，
原生开发 sysroot 只保留动态 C 链接所需的头文件、CRT、链接脚本和兼容
归档，不打包静态 `libc.a`/`libm.a`、locale 源数据或 GCC 插件开发头。
板上 `gcc` 支持普通动态 C 程序（包括 `-pthread` 和 `-lm`），不提供
`gcc -static` 的完整 glibc 静态链接环境；主机交叉工具链仍保留完整 sysroot。

## 板上现场编译

启动新 rootfs 后，不需要设置额外环境变量：

```sh
gcc --version
gcc -dumpmachine

mkdir -p /root/.gcc-tmp
export TMPDIR=/root/.gcc-tmp

gcc -O0 -Wall -Wextra -Werror \
  /usr/share/gemmont-examples/hello.c -o /root/hello
/root/hello
```

预期 `gcc -dumpmachine` 输出 `loongarch32-linux-gnusf`，程序输出
`Hello from Gemmont GCC 16 on LA32R!`。连接 VGA 显示器并启动带
Xilinx framebuffer 驱动的新内核后，还可以在串口中现场编译色条程序：

```sh
gcc -O2 -Wall -Wextra -Werror \
  /usr/share/gemmont-examples/vga-colorbars.c -o /root/vga-colorbars
/root/vga-colorbars
```

程序根据 `Xilinx` framebuffer 名称自动定位 VGA 并绘制 640×480
色条；命令输入仍走串口。仓库的
`make board-smoke-test` 会通过 SSH 自动完成 Hello World 的编译、
执行和 ELF ABI 检查，并检查 framebuffer 后运行色条程序。

连接 NT35510 LCD 并使用带 Chiplab LCD framebuffer 驱动的内核与
bitstream 后，可在板上现场编译 LCD 示例：

```sh
gcc -O2 -Wall -Wextra -Werror \
  /usr/share/gemmont-examples/lcd-colorbars.c -o /root/lcd-colorbars
/root/lcd-colorbars
```

该程序根据 framebuffer 的 `chiplab-lcd` 名称自动定位 LCD，不依赖它
是 `/dev/fb0` 还是 `/dev/fb1`。四角标记依次为红、绿、蓝、白，可用于
检查方向、裁剪和 RGB565 通道顺序。

将 SSH 公钥写入镜像：

```sh
SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub" make
```

若已有同版本 Linux 发布包，可把其中的已签名模块一并装入 rootfs：

```sh
LINUX_RELEASE_ARCHIVE=../linux-7.1.4-SuperscalarCrash-la32r-v0.1.6-loongarch32.tar.zst \
SSH_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub" make
```

脚本会拒绝含有多个模块版本或不安全路径的归档。生成嵌入式内核时应让
`KERNEL_LOCALVERSION` 与模块目录严格一致，例如：

```sh
CPU_HZ=72000000 \
KERNEL_LOCALVERSION=-SuperscalarCrash-la32r-v0.1.6 \
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
