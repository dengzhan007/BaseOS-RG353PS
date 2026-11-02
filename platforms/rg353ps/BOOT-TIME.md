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

## Where the remaining 1.890 s goes

bootstage, stable to 1 ms across the three boots:

| stage | at counter origin | segment |
|---|---|---|
| `reset` | 0 ms | counter origin |
| `board_init_f` | 7 ms | entry to `board_init_f` |
| `board_init_r` | 52 ms | pre-relocation init = **45 ms** |
| `main_loop` | 354 ms | post-relocation init + driver model = **302 ms** |
| `bootm_start` | 1556 ms | **extlinux scan + FAT + reading 21.6 MB = 1202 ms** |
| `start_kernel` | 1566 ms | bootm prep = 10 ms |

- The data cache is doing its job: pre-relocation init is **45 ms**. Upstream
  measured 570 ms with the MMU off and 40 ms with it on; this is the same
  number on the same SoC.
- Kernel entry → timekeeping origin is 324 ms (`1890 − 1566`), inside the
  `before Linux` figure but outside bootstage.
- **The load segment is now the largest item, and it is not all card read.**
  21.6 MB at the measured 24.6 MB/s is 0.84 s, so ~0.35 s is GPT walking,
  `bootflow scan -lb`, `extlinux.conf` parsing and the FAT metadata.

## What is worth doing next

| lever | expected | cost |
|---|---|---|
| Raw FIT at a fixed sector, no scan and no filesystem (`mmc read` + `bootm`) | ~0.3 s of the 0.35 s load overhead | medium: touches build-image and the update path |
| U-Boot control tree / `blkcache` for the GPT walk | ~0.1 s | low |
| Kernel compression | 0.06–0.26 s net | not worth it: changes the image format and A/B layout |
| `initcall_blacklist` or, better, unused drivers off in the kernel config | to be measured | low; we build the kernel, unlike upstream |

Compression and the 1800 MHz decompression path are dead ends here: the read
already runs at 24.6 MB/s, so shrinking the payload buys ~0.56 s while the
decode costs 0.3–0.5 s.
