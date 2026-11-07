# Build environment notes (2026-11-06)

The isolated build ran in WSL Ubuntu 24.04 with Docker 29.9.2, in a
`git worktree add --detach` based on `origin/feature/rg353ps-mtp-integrity-test`
at `2809e62463e28c1cc32746138d1fe9a11cdd853d`. All products live under
`work/rg353ps-mtp-only-test/`. No existing work directory, kernel cache or
firmware cache was removed.

The first U-Boot attempt stalled in `apt-get install` inside the build
container: the official Debian mirror is slow from this host. The retry used
the TUNA mirror, as follows (local-only, never committed):

- `DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian` (native env var
  in `build-uboot.sh` / `build-image.sh`)
- `ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22` (native
  env var in `build-rootfs.sh`)
- `build-kernel.sh` has no mirror env var, so a local-only block was inserted
  before its `apt-get -qq update` in the detached worktree. No build logic,
  kernel source change, USB logic or rootfs source file was altered.

- `BASEOS_USB_PROFILE=release` was used for the rootfs step only.
- All five steps shared the same `RG353PS_WORK`.
- Temporary boot hook: `/root/work/baseos-rg353ps-mtp-only/wt/work/rg353ps-mtp-only-test/rootfs/usr/sbin/mtp-only-test-prepare`, inserted immediately before the USB Gadget manager start block in rcS (after user-data init).
- `sh -n` passed on the helper, the hook and the patched staged `rcS`.

Raw build logs kept in `logs/`:

- `firmware.log`
- `image-final.log`
- `image.log`
- `kernel.log`
- `rootfs.log`
- `uboot.log`

