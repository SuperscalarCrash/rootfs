# v0.2.6 FPGA / v0.1.1 Linux board test

Test date: 2026-07-24

## Inputs

- `Gemmont-v0.2.6-nscscc.zip`
  - SHA-256:
    `f84c5d9600adf1749ba15fe95b6a298ddba6d453c63f26b24bf64046a677ddc5`
  - Gemmont source: `b7ef4dd18ca0ae174fcc1fa7bc997f7ed58011ae`
  - Chiplab source: `b518aec9fa634bf2c1dd2c2778f50e7bb1edca37`
- `linux-7.1.4-SuperscalarCrash-la32r-v0.1.1-loongarch32.tar.zst`
  - SHA-256:
    `602995f356807379b57dc13ae63f30426af6fdfce71d68357c57b69ccc760ad9`

The FPGA was configured from the package's U-Boot bitstream. The unmodified
release `vmlinux` was loaded first and reached the expected panic because that
image has no initramfs and its forced command line uses `rdinit=/init`.

The second image was built from the Linux v0.1.1 source with this project's
`rootfs.cpio.gz` embedded. Its release string was kept exactly equal to the
module directory:

```text
7.1.4-SuperscalarCrash-la32r-v0.1.1
```

## Passed checks

- U-Boot TFTP load and `bootelf`
- Linux LA32R boot at 72 MHz with 128 MiB RAM
- devtmpfs setup, BusyBox init and serial root login
- OpenSSH 10.3p1 server, public-key login and client
- DHCP and bidirectional ICMP
- Buildroot self-test
- loading the `sit`, `tunnel4` and `ip_tunnel` modules
- read-only NAND discovery and MTD reporting

The NAND probe found the two existing bad blocks at eraseblocks 515 and 1023.
No erase, format, attach or write operation was performed.

## Linux DMFE correction

Linux v0.1.1 used a fixed 5 microsecond delay between stopping and restarting
the Chiplab MAC state machines. On this FPGA the start request could arrive
before CSR5 reported STOP and was then discarded by the RTL. The symptoms were
setup-frame timeouts, DHCP receive traffic followed by a stopped transmitter,
and an unreachable SSH service.

The tested Linux tree polls CSR5 with a bounded timeout before writing the
start bits. With that correction the board and `fpgadev` exchanged ICMP packets
without loss and SSH completed the smoke test.

## Remaining CPU/kernel stability issue

The system reaches a usable shell, but the exact v0.2.6 FPGA still showed
intermittent user-space memory corruption under repeated process/SSH activity.
Observed victims included BusyBox `logger`, `sh`, and `sshd-session`; the
kernel reported invalid accesses inside `ld-2.28.so`, BusyBox, and glibc.

The current evidence does not distinguish a residual Gemmont execution bug
from a defect in the new LA32R kernel TLB/cache integration. It does show that
this is below the OpenSSH or init-script layer: unrelated dynamically linked
processes fail at different addresses. The image is suitable for continued
board bring-up, but this v0.2.6/Linux v0.1.1 combination should not yet be
treated as production-stable. The full serial log is kept locally at:

```text
artifacts/board-test/serial-v0.2.6-linux-v0.1.1-buildroot-dmfe.log
```

The smoke test itself is reproducible with:

```sh
BOARD_ADDRESS=172.25.2.56 JUMP_HOST=fpgadev make board-smoke-test
```
