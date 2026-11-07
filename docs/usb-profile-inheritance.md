# USB profile inheritance on first boot

## Why this document exists

While preparing the **MTP-only Release acceptance image** (PR #5 work), a P0
defect was found: a brand-new, blank user-data partition could turn a Release
image (`usb_debug=no`) back into a Development image with RNDIS/SSH enabled.

`baseos-init-userdata::ensure_card_config()` seeds
`/mnt/SDCARD/baseos.conf` once, on first boot. The old seed contained an
**active** line:

```ini
usb_debug=yes
```

`baseos-usb-debug::config_value()` resolves keys in this order:

1. `/mnt/SDCARD/baseos.conf`
2. `/mnt/boot/baseos.conf`
3. `/etc/baseos.conf`

The card copy always wins, so the seed silently overrode the image default.
No gadget, kernel, DWC3, supervisor or recovery logic was involved; this was
purely a default-configuration inheritance bug.

## The fix

The generated card config no longer contains an active `usb_debug=` or
`usb_mtp=` line. Both keys are left as **commented examples** so the image
profile is inherited unless the owner explicitly sets a value. `debug=no` and
the other existing user-facing keys are unchanged. An existing non-empty card
config is still never rewritten or deleted.

The resolution order itself is unchanged: an explicit card value still wins.

| Image profile | Card `usb_debug` | Effective value | USB functions |
| --- | --- | --- | --- |
| Development (`yes`) | unset (new card) | `yes` | network + SSH + MTP |
| Release (`no`) | unset (new card) | `no` | MTP only |
| Release (`no`) | explicit `yes` | `yes` | network + SSH + MTP |
| Development (`yes`) | explicit `no` | `no` | MTP only |

`usb_mtp` follows the same rule.

## Existing cards are NOT migrated

A card seeded by an older build may already contain an active
`usb_debug=yes`. There is no way to tell whether that value was written by the
old seed or deliberately set by the owner, so this fix **does not** migrate,
delete or rewrite any existing card config. That is intentional.

On such a card, `usb_debug=yes` continues to override a Release image. To
restore inheritance, the owner removes that one active line from
`/mnt/SDCARD/baseos.conf` (or deletes the whole file to get a fresh seed).
No automatic cleanup is performed.

## Regression coverage

`tests/test-rg353ps-usb-profile-inherit.sh` extracts the **real**
`ensure_card_config()` and `config_value()` bodies from the production scripts
and redirects only their three hard-coded config paths into a temporary
sandbox. It covers:

1. a fresh seed has no active `usb_debug` / `usb_mtp`;
2. Development image + fresh card resolves to `yes`;
3. Release image + fresh card resolves to `no`;
4. card `yes` still overrides a Release image;
5. card `no` still overrides a Development image;
6. `usb_mtp` inherits the image (both values) and honours an explicit card value;
7. an existing non-empty card config is byte-identical after seeding;
8. all reads/writes stay inside a temporary sandbox.

It is invoked from `tests/test-rg353ps-usb-mtp.sh`, which the existing
`RG353PS USB storage mode checks` workflow already runs, so the regression is
part of every PR check.
