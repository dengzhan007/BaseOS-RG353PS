# RG353PS speaker-amplifier power-up test

**Status: test-only kernel change. Not a release default.**

## Hypothesis

The RG353PS device tree describes the external speaker stage as a generic `simple-audio-amplifier` controlled by GPIO4_PC2. The repository does not identify the physical amplifier IC. SGM4865 is one possible hypothesis, not a confirmed board-level part number.

The existing userspace experiment keeps `Internal Speakers Switch` off while the default PCM and softvol are initialized, sets `BaseOS Master` to minimum, and then re-enables the DAPM route. The pop remains. This narrows the remaining transient to the speaker-path / external-amplifier power-up sequence; digital softvol attenuation alone has not suppressed it.

## Test change

The kernel build applies an opt-in `power-on-delay-ms` property to the RG353PS speaker-amplifier node:

- The generic `simple-audio-amplifier` driver asserts the enable GPIO at DAPM `PRE_PMU`, rather than `POST_PMU`.
- It waits for the node's `power-on-delay-ms` value (clamped to 1000 ms) before the DAPM power-up sequence continues.
- The RG353PS node sets this property to 250 ms.
- Power-down remains on `PRE_PMD`; GPIO polarity, RK817 mixer gains, `BaseOS Master`, and frontend volume ownership are unchanged.
- Other simple-amplifier nodes without the property retain their original behavior.

This tests whether allowing the external amplifier to settle before the speaker signal path completes power-up avoids the transient. It does not prove the installed chip is SGM4865 and does not add a separate hardware MUTE control.

## Device validation

After a clean full-image flash:

1. Listen for the pop during a cold boot, especially when the BaseOS wordmark is first drawn.
2. From SSH, with no game or music playing and at low volume, toggle `Internal Speakers Switch` off and on. Check whether the transition itself clicks.
3. Confirm normal audio during the frontend, game effects, music, volume hotkeys, suspend, and resume.

Interpretation:

- Pop reduced or gone: DAPM/GPIO ordering and amplifier settling time are relevant; the delay value may still need measurement.
- Pop unchanged: the assumed amplifier settling behavior or 250 ms interval is insufficient, or the physical amplifier differs from the hypothesized part.

Do not merge this test-only behavior into the release branch until the device test is complete.