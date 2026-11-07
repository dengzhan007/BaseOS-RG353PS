# Build environment (P0-fixed rebuild)

- Local-only integration worktree: `/root/work/rg353ps-mtp-only-fixed/wt`,
  detached at `fbb7d8346c19ceec0e140380aa461af6f1ce1542`, with the fix commit
  `7e29495233809c36c17f7475f064d4e421bffcad` applied via `git cherry-pick --no-commit`.
  It was never committed or pushed; PR #5 and main were not modified.
- New isolated work directory: `work/rg353ps-mtp-only-fixed/`; the previous
  `work/rg353ps-mtp-only-test/` image, logs and build tree are all retained.
- No source patch to build scripts was needed this time: rootfs uses the
  native `ALPINE_MIRROR`, image uses the native `DEBIAN_MIRROR` (TUNA),
  and kernel/U-Boot/firmware were reused rather than rebuilt.
- `BASEOS_USB_PROFILE=release` for rootfs; image assembled afterwards.
- Temporary MTP data hook lives only in the staged `$WORK/rootfs`; the
  git-tracked `rcS` and rootfs sources were not modified.
- `sh -n` passed on the helper, the hook and the patched staged `rcS`.

