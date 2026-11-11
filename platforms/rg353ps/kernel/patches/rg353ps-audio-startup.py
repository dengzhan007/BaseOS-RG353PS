#!/usr/bin/env python3
"""Apply an opt-in DAPM amplifier power-up settling delay for RG353PS test builds."""
from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: rg353ps-audio-startup.py <linux-source-root>")

root = Path(sys.argv[1])
driver_path = root / "sound/soc/codecs/simple-amplifier.c"
dts_path = root / "arch/arm64/boot/dts/rockchip/rk3566-anbernic-rg353ps.dts"
binding_path = root / "Documentation/devicetree/bindings/sound/simple-audio-amplifier.yaml"

for path in (driver_path, dts_path, binding_path):
    if not path.is_file():
        raise SystemExit(f"required kernel source file is missing: {path}")

driver = driver_path.read_text()

# Keep the delay local to the opt-in DT node; other simple amplifiers are unchanged.
for header in ("#include <linux/delay.h>\n", "#include <linux/of.h>\n"):
    if header.strip() not in driver:
        anchor = "#include <linux/module.h>\n"
        if driver.count(anchor) != 1:
            raise SystemExit(f"cannot uniquely locate include anchor for {header.strip()}")
        driver = driver.replace(anchor, header + anchor, 1)

event_match = re.search(
    r"static int (?:simple_amp_power_event|drv_event)\(.*?\n\}",
    driver,
    flags=re.S,
)
if not event_match:
    raise SystemExit("cannot locate simple-amplifier DAPM power-event function")

event_fn = event_match.group(0)
if "power-on-delay-ms" not in event_fn:
    event_fn_new = event_fn
    if event_fn_new.count("int val;") != 1:
        raise SystemExit("cannot uniquely locate DAPM event local-variable declaration")
    event_fn_new = event_fn_new.replace(
        "int val;",
        "int val;\n\tu32 power_on_delay_ms = 0;",
        1,
    )
    if event_fn_new.count("case SND_SOC_DAPM_POST_PMU:") != 1:
        raise SystemExit("cannot uniquely locate amplifier POST_PMU event")
    event_fn_new = event_fn_new.replace(
        "case SND_SOC_DAPM_POST_PMU:",
        "case SND_SOC_DAPM_PRE_PMU:",
        1,
    )
    gpio_call = re.search(r"\n\s*gpiod_set_value_cansleep\([^;]+\);", event_fn_new)
    if not gpio_call:
        raise SystemExit("cannot locate amplifier enable GPIO write")
    insert = """
\tif (event == SND_SOC_DAPM_PRE_PMU &&
\t    !of_property_read_u32(c->dev->of_node, "power-on-delay-ms",
\t\t\t\t  &power_on_delay_ms)) {
\t\t/* Bound a malformed or unexpected DT value to one second. */
\t\tif (power_on_delay_ms > 1000)
\t\t\tpower_on_delay_ms = 1000;
\t\tif (power_on_delay_ms)
\t\t\tmsleep(power_on_delay_ms);
\t}
"""
    at = gpio_call.end()
    event_fn_new = event_fn_new[:at] + insert + event_fn_new[at:]
    driver = driver[:event_match.start()] + event_fn_new + driver[event_match.end():]

# Switch only the basic external-amplifier widget to PRE_PMU; leave PGA variants unchanged.
old_event_flags = "(SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_PRE_PMD)"
new_event_flags = "(SND_SOC_DAPM_PRE_PMU | SND_SOC_DAPM_PRE_PMD)"
if old_event_flags in driver:
    driver = driver.replace(old_event_flags, new_event_flags, 1)
elif new_event_flags not in driver:
    raise SystemExit("cannot locate simple-amplifier DAPM event flags")

if driver != driver_path.read_text():
    driver_path.write_text(driver)

# Set the delay only on RG353PS's external speaker-amplifier node.
dts = dts_path.read_text()
node_start = dts.find("spk_amp: audio-amplifier")
if node_start < 0:
    raise SystemExit("cannot locate RG353PS speaker amplifier node")
node_tail = dts[node_start:]
node_end_match = re.search(r"\n[ \t]*};", node_tail)
if not node_end_match:
    raise SystemExit("cannot locate end of RG353PS speaker amplifier node")
node_end = node_start + node_end_match.start()
node = dts[node_start:node_end]
delay_line = "\t\tpower-on-delay-ms = <250>;\n"
if "power-on-delay-ms" not in node:
    enable_match = re.search(
        r"(?m)^([ \t]*)enable-gpios = <&gpio4 RK_PC2 GPIO_ACTIVE_HIGH>;[ \t]*$",
        node,
    )
    if not enable_match:
        raise SystemExit("cannot locate RG353PS amplifier enable-gpios")
    insert_at = enable_match.end()
    node = (
        node[:insert_at]
        + "\n"
        + enable_match.group(1)
        + "power-on-delay-ms = <250>;"
        + node[insert_at:]
    )
    dts = dts[:node_start] + node + dts[node_end:]
elif "power-on-delay-ms = <250>;" not in node:
    raise SystemExit("RG353PS amplifier already has a different power-on-delay-ms")
dts_path.write_text(dts)

# Document the optional property in the binding, so the test does not leave DT schema drift.
binding = binding_path.read_text()
if "power-on-delay-ms:" not in binding:
    enable_block = """  enable-gpios:
    maxItems: 1
"""
    delay_block = """  enable-gpios:
    maxItems: 1

  power-on-delay-ms:
    description: >
      Optional settling delay after asserting enable-gpios and before the
      amplifier DAPM power-up sequence continues.
    $ref: /schemas/types.yaml#/definitions/uint32
    maximum: 1000
"""
    if binding.count(enable_block) != 1:
        raise SystemExit("cannot uniquely locate simple-amplifier binding enable-gpios property")
    binding = binding.replace(enable_block, delay_block, 1)
    binding_path.write_text(binding)

print("Applied RG353PS speaker-amplifier pre-power-up settling delay: 250 ms")
