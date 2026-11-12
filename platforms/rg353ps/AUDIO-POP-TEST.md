# RG353PS startup audio pop — investigation closed

**Status: software investigation closed. BaseOS 1.2.9 restores the 1.2.8 audio implementation.**

## Decision

Repeated device testing found no meaningful audio improvement from the 1.2.9 audio-sequencing candidate compared with the official 1.2.8 behavior. The release therefore removes the experimental audio changes and keeps the established 1.2.8 startup sequence.

The cold-start pop may remain as a faint, known limitation. It is not claimed as fixed in 1.2.9. No further software changes for this issue are planned.

## Experiments excluded from the release

- DAPM speaker-pin gating before PCM initialization.
- Minimum `BaseOS Master` softvol level during speaker-path reconnection.
- The 100 ms userspace settling wait.
- The kernel `PRE_PMU` change and `power-on-delay-ms = <250>` amplifier delay.
- Early amplifier-enable GPIO assertion (S1), which made cold boot and hot reboot pops louder.

These experiments did not provide a sufficient improvement to justify changing the released audio path. The S1 experiment is rejected and must not be used.

## Release behavior

The `baseos-audio-init` script and kernel audio path in the 1.2.9 release are the same as the official 1.2.8 implementation. This document records the decision only; it is not an active test plan.