# Boot time — RG353PS

Measured on the unit, 2026-11-02. Three warm reboots per build; the first boot
after a U-Boot change is discarded, because the audio-init pass that lands in
the first one adds up to ~1 s to `Linux to menu` (see history: the same
artifact was recorded for 1.1.5).

## How it is measured

The upstream method ([docs/boot-time.md](../../docs/boot-time.md)), adapted:

- **`before Linux`** comes from `boot-clock` reading `CNTVCT_EL0`. The ARM
  generic counter is not reset by the kernel, so the figure is a counter
  reading: the value at the sample minus `CLOCK_MONOTONIC_RAW`, i.e. counter
  origin → the kernel's timekeeping origin. On this unit the origin sits at or
  just before U-Boot — bootstage's `reset` mark is 0 and `board_init_f` 7 ms —
  so the bootrom, SPL and BL31 are **not** inside any figure here. That is why
  both sides of the comparison must use this clock.
- **U-Boot's internal split** comes from bootstage (patch `0009`), which records
  each stage in the device tree it hands to the kernel. On the device:

  ```sh
  for r in /proc/device-tree/bootstage/*/; do
      n=$(tr -d '\000' < "$r/name")
      t=$(od -An -tx1 "$r/mark" | tr -d ' \n')
      printf '%-18s %d ms\n' "$n" "$((0x$t/1000))"
  done
  ```

  `mark` is the same arch counter in microseconds, so these rows share the
  origin above.
- **The kernel clock was checked, not assumed.** Write the uptime into `/dev/kmsg`
  and read the printk timestamp back:

  ```sh
  u=$(cut -d' ' -f1 /proc/uptime); echo "probe $u" > /dev/kmsg
  dmesg | grep probe | tail -1
  ```

  On 7.2.7 the two agree to ~20 ms (`[20.096]` against uptime `20.08`), so
  printk and uptime share the kernel origin — unlike the vendor kernel upstream,
  whose printk is power-on-relative. Do not mix the two clocks.

## Result

Same unit, same rootfs; only U-Boot changed (0009 bootstage + 0010 dcache).

| | before (1.2.2) | after (1.2.2 + 0009/0010) | Δ |
|---|---|---|---|
| `before Linux` | 2.545–2.546 s | **1.890–1.891 s** | **−0.655 s** |
| `Linux to menu` | 2.16–2.60 s | 2.23–2.37 s | ≈ −0.1 s |
| `total` | 4.706–5.145 s | **4.120–4.261 s** | **−0.68 s** (mean) |

## Final state (1.2.3)

Two more U-Boot changes landed after the measurement above: `0012` skips the
display-ID probe (the panel is selected from the DTB path already) and `0014`
drops the 200 ms startup buzz. Both live inside `board_late_init`, which the
next section splits into 235 ms.

| | 1.2.2 | +0009/0010 | +0012/0014 (1.2.3) |
|---|---|---|---|
| `before Linux` | 2.545–2.546 s | 1.890–1.891 s | **1.654–1.655 s** |
| `Linux to menu` | 2.16–2.60 s | 2.23–2.37 s | 2.12–2.37 s |
| `total` | 4.706–5.145 s | 4.120–4.261 s | **3.75–3.92 s** |

Three balanced warm boots on 1.2.3 read 1.657 / 2.14 / 3.797 s. The boot logo
now appears at 1.50 s instead of ~1.9 s, because rcS draws it as soon as
storage is mounted rather than after the 400 ms key-sampling window.

The sections below still describe the 1.890 s boot. Their per-stage numbers
were taken in that configuration; nothing since has moved those stages, the
two extra patches only removed calls from the end of `board_late_init`.

## Where the remaining 1.890 s goes

bootstage, stable to 1 ms across the three boots:

| stage | at counter origin | segment |
|---|---|---|
| `reset` | 0 ms | counter origin |
| `board_init_f` | 7 ms | entry to `board_init_f` |
| first `board_r` initcall | 31 ms | pre-relocation init = **24 ms** |
| `initr_bootstage` | 53 ms | labelled `board_init_r`, but the mark is inside `initr_bootstage()`, not at entry |
| `main_loop` | 354 ms | post-relocation init + driver model = **323 ms** |
| `bootm_start` | 1556 ms | **extlinux scan + FAT + reading 21.6 MB = 1202 ms** |
| `start_kernel` | 1566 ms | bootm prep = 10 ms |

- The data cache is doing its job: pre-relocation init is **24 ms**. Upstream
  measured 570 ms with the MMU off and 40 ms with it on; this is better than
  theirs on the same SoC. (The 45 ms this document used to claim came from
  reading the `board_init_r` record as the entry — it is not.)
- Kernel entry → timekeeping origin is 324 ms (`1890 − 1566`), inside the
  `before Linux` figure but outside bootstage.
- **The load segment is the largest single block, and it is not all card
  read.** 21.6 MB at the measured 24.6 MB/s is 0.84 s, so ~0.35 s is GPT
  walking, `bootflow scan -lb`, `extlinux.conf` parsing and FAT metadata.
- Of the 323 ms of post-relocation init, one call accounts for 235 ms; the
  next section splits it.

## U-Boot post-relocation init, attributed

bootstage only marks `board_init_f`, `board_init_r`, `main_loop` and the bootm
stages, and the `board_init_r` mark sits inside `initr_bootstage()`, so the
whole post-relocation init used to be one number. Patch `0011` adds
`CONFIG_BASEOS_INITCALL_TIMING`, which records a mark before every `INITCALL()`
in `initcall_run_r()`; one boot then gives the split. Build it with
`CONFIG_BOOTSTAGE_RECORD_COUNT=120` as well — 45 marks do not fit in the
default 50 alongside the existing ones.

Warm reboot, arch counter in ms, deltas are the time spent in the call that
precedes each mark:

| call | ms | note |
|---|---|---|
| `board_late_init` | **234.8** | split further below — 200.1 of it is one `mdelay` |
| `initr_dm` | 39.2 | bind and probe 37 devices |
| `initr_malloc` | 20.7 | |
| `power_init_board` | 16.1 | regulator init over I2C |
| `initr_of_live` | 7.9 | |
| pre-relocation sequence (68 calls) | 24.0 | measured from the `board_init_f` mark to the first `board_r` call |
| everything else | ~13 | `initr_env` 1.4, `initr_reloc` 0.9, the remaining 33 under 1 ms |

`board_late_init` itself is one call, so patch `0013` adds marks inside
`rk_board_late_init()` under the same switch. Measured the same way:

| step | ms | note |
|---|---|---|
| `setup_boot_mode()` | 0.2 | the ADC download-key probe is not the cost |
| `set_gd_value()`, three `env_set()` | 0.0 | |
| `rgxx3_detect_display()` | **34.5** | DSI host probe, DSI attach, DCS read of the panel ID |
| LED writes | 0.0 | |
| `startup_buzz()` | **200.1** | `pwm_set_enable`, `mdelay(200)`, `pwm_set_enable` |

Two corrections to what this document said before the marks existed:

- The panel detection is 34.5 ms, not 235 ms. It is still dead weight —
  **nothing consumes its result**: it ends in `env_set("panel", …)`, and
  neither `extlinux.conf` nor the kernel command line references `${panel}`
  (0 occurrences on the device). It exists because the 353 series shipped two
  panels and the boot script used to patch the DT with the detected one; this
  platform ships a single DTB and the kernel probes the panel itself.
- `startup_buzz()` **does** run, and it is the 200 ms. It finds the PWM
  (`pwm@fe6e0010`) even though that node reads `status = "disabled"` in the
  preprocessed device tree, so the earlier claim that it returns early was
  wrong. The delay is deliberate — it is how long the chime needs to be
  audible.

Both are now switchable: `CONFIG_RGXX3_SKIP_PANEL_ID` (0012) and
`CONFIG_RGXX3_SKIP_STARTUP_BUZZ` (0014), both on in `uboot.config`.

Result, three warm reboots: `before Linux` **1.891 → 1.654 / 1.655 / 1.655 s**,
`total` 4.09–4.26 → **3.75–3.92 s**. The chime is gone unless
`CONFIG_RGXX3_SKIP_STARTUP_BUZZ` is deleted from `uboot.config`.

In userspace the boot logo now goes up at `rcS` 1.50 s (absolute ≈ 3.16 s)
instead of after the 400 ms key sample at ~1.9 s: `storage mounted` 1.41 →
`boot logo drawn` 1.50 in `/run/boot-marks`. It is drawn twice only if the
first attempt failed.

Note the diagnostic build costs ~40 ms of its own (1.890 → 1.930 s): every
mark is a DM timer read plus `show_boot_progress()`, and there are 45 of them.

## What is worth doing next

| lever | expected | cost |
|---|---|---|
| Skip the panel-ID detection in U-Boot (keep the VO power domain and the reset release) | **~0.23 s** | low, but it touches the display hand-off — verify the panel still comes up |
| Raw FIT at a fixed sector, no scan and no filesystem (`mmc read` + `bootm`) | ~0.3 s of the 0.35 s load overhead | medium: touches build-image and the update path |
| `blkcache` for the GPT walk | ~0.1 s | low |
| Kernel compression | 0.06–0.26 s net | not worth it: changes the image format and A/B layout |
| `initcall_blacklist` / kernel config trimming | only ~108 ms — measured below, no single expensive initcall | low |

Compression and the 1800 MHz decompression path are dead ends here: the read
already runs at 24.6 MB/s, so shrinking the payload buys ~0.56 s while the
decode costs 0.3–0.5 s.

## Kernel init, attributed

One boot with `initcall_debug loglevel=7 log_buf_len=8M` appended to
`APPEND` in `/mnt/boot/extlinux/extlinux.conf` (restore the file afterwards;
`initcall_debug` output is KERN_DEBUG, so `loglevel=3` would hide it). 828
initcalls; the kernel reaches userspace at ~1.05 s.

Kernel phase (initcalls finishing before userspace), total **635 ms**:

| initcall | ms | note |
|---|---|---|
| `rk3x_i2c_driver_init` | **134** | upstream measured 146 ms and kept it: the PMIC and muic buses live here |
| `cma_init_reserved_areas` | **92** | `CONFIG_CMA_SIZE_MBYTES=128` |
| `jent_mod_init` | **70** | jitterentropy startup self-test |
| `of_platform_default_populate_init` | 48 | structural |
| `clk_debug_init` | 38 | debugfs clock summary, pure diagnostic |
| `rk817_charger_driver_init` | 25 | |
| `param_sysfs_builtin_init` | 16 | |
| `chr_dev_init` / `slab_late_init` / `rockchip_drm_init` | 13 / 11 / 10 | |

rcS phase — module loads, **already backgrounded** in `rcS` (`( … ) &`), so
they are off the critical path but still compete for CPU and I/O. They explain
most of the ±0.1 s spread in `Linux to menu`:

| initcall | ms |
|---|---|
| `deferred_probe_initcall` | **447** |
| `rtw_8821cs_driver_init` | **144** |
| `panfrost_driver_init` | 6 |

What this rules out: there is no 300 ms initcall waiting to be blacklisted.
The kernel's 1.05 s is spread across 828 of them plus 0.20 s of fbcon
(`Console: switching to colour frame buffer device`) and 0.17 s of SD tuning.
The only cheap kernel-side wins are ~108 ms: `CONFIG_CRYPTO_JITTERENTROPY`
(70 ms — but check that crng init does not regress) and the debugfs clock
summary (38 ms). Shrinking CMA trades GPU/video headroom for ~50 ms.

So the remaining fat is in U-Boot, not the kernel: 323 ms of post-relocation
init (235 ms of it one call) and ~0.36 s of scan/FAT overhead in the load
segment.

