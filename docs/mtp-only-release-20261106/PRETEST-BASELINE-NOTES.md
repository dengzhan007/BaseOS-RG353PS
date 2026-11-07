# Pre-test Windows PnP baseline (NOT an acceptance result)

Captured on the host before the spare test card was ever booted, to verify
the one-shot script's `device not present` branch and to document the
currently connected development-profile device.

- Run ID used by the script: `20261106-120429-62aa6d`
- Overall pass: **False** (expected, the MTP-only image was not booted)
- Checks:

  | Check | Status | Detail |
  | --- | --- | --- |
  | tool_present | PASS | F:\workspace\2026-10-28-22-11-37\.tmp-doc\mtp-only\wt\tools\mtp\mtp_integrity.py |
  | python_available | PASS | python |
  | pnp_pid_0009 | FAIL | VID_2207&PID_0009 matches=0 |
  | no_pid_0007_0008 | FAIL | forbidden PID matches=3 |
  | no_rndis_ncm_adapter | FAIL | device-provided network adapters=1 |
  | wpd_rg353ps | PASS | WPD/RG353PS entries=1 |
  | wpd_sdcard_storage | PASS | WPD storages=RG353PS |
  | device_ready | FAIL | PID_0009 device did not appear within the finite probe window; see PnP table above |

- VID_2207 devices currently present:

  - `RG353PS` | WPD | `USB\VID_2207&PID_0008&MI_02\7&26A4B16B&0&0002`
  - `Remote NDIS Compatible Device` | Net | `USB\VID_2207&PID_0008&MI_00\7&26A4B16B&0&0000`
  - `USB Composite Device` | USB | `USB\VID_2207&PID_0008\BASEOS-RG353PS`

The device currently enumerates as **PID_0008** with a `Remote NDIS
Compatible Device`: that is the development profile (network + MTP).
It is exactly what the MTP-only Release image must NOT enumerate as
(`VID_2207&PID_0009` only). This also confirms the PnP checks are
looking at real device IDs rather than an empty network-adapter list.

> This is evidence of the script's self-test and of the pre-test host state.
> It is NOT a hardware acceptance result.

