# Host-script self-test (NOT an MTP-only acceptance result)

`run-mtp-only-acceptance.ps1` was run once on this Windows host **before the
spare test card was ever booted**, to verify its finite-wait / device-not-present
branch and PnP evidence collection. Raw output: `host-script-self-test.json`
and `host-script-self-test.md`.

The connected device was the existing **Development-profile** unit, which
enumerates as `VID_2207&PID_0008` with a `Remote NDIS Compatible Device`.
The script correctly reported FAIL (no PID_0009, forbidden PID present,
device-provided network adapter present) and listed the real PnP IDs.

**Classification**: host-script self-test / negative control. It is not a
hardware acceptance result for the MTP-only Release image. The real
`mtp-only-host-report.json` / `.md` will only exist after the spare card is
booted and the one-shot script is run.

