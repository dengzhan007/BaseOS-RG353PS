"""Inject low-frequency DWC3 reconnect dev_dbg callsites into a Linux tree.

Usage: inject-reconnect-diag.py /path/to/linux-7.2.7
This file lives in the kernel tools directory, which build-kernel.sh mounts
at /inputs inside the build container. It is idempotent: every edit is
guarded by a marker, so a cached source tree is never rewritten twice.
"""

from pathlib import Path
import sys

SRC = Path(sys.argv[1])
NL = chr(92) + "n"
PREFIX = "RG353PS DWC3 RECONNECT "


def line(fmt, args):
    return ('\tdev_dbg(dwc->dev, "' + PREFIX + fmt + NL + '", ' + args + ');\n')


def inject(path, edits):
    source = SRC / path
    text = source.read_text()
    changed = 0
    for label, anchor, replacement in edits:
        marker = PREFIX + label
        if marker in text:
            continue  # idempotent: a cached source tree is not rewritten twice
        count = text.count(anchor)
        if count != 1:
            raise SystemExit(
                "Could not uniquely inject %s into %s: anchor found %d times\n%s"
                % (label, path, count, anchor[:120])
            )
        text = text.replace(anchor, replacement, 1)
        changed += 1
    source.write_text(text)
    return changed


gadget_edits = [
    (
        "DISCONNECT entry",
        "static void dwc3_gadget_disconnect_interrupt(struct dwc3 *dwc)\n{\n",
        "static void dwc3_gadget_disconnect_interrupt(struct dwc3 *dwc)\n{\n"
        + line(
            "DISCONNECT entry: connected=%d pullups=%d softconnect=%d state=%d speed=%d",
            "dwc->connected, dwc->pullups_connected, dwc->softconnect, "
            "dwc->gadget->state, dwc->gadget->speed",
        ),
    ),
    (
        "PULLUP entry",
        "\tis_on = !!is_on;\n",
        "\tis_on = !!is_on;\n"
        + line(
            "PULLUP entry: is_on=%d pullups=%d connected=%d state=%d",
            "is_on, dwc->pullups_connected, dwc->connected, dwc->gadget->state",
        ),
    ),
    (
        "PULLUP pm",
        "\tret = pm_runtime_get_sync(dwc->dev);\n",
        "\tret = pm_runtime_get_sync(dwc->dev);\n"
        + line(
            "PULLUP pm: ret=%d is_on=%d branch=%s",
            'ret, is_on, ret < 0 ? "error" : (!ret ? "no_resume" : "proceed")',
        ),
    ),
    (
        "PULLUP short",
        "\tif (dwc->pullups_connected == is_on) {\n"
        "\t\tpm_runtime_put(dwc->dev);\n"
        "\t\treturn 0;\n"
        "\t}\n",
        "\tif (dwc->pullups_connected == is_on) {\n"
        + line(
            "PULLUP short: is_on=%d pullups=%d reason=same_state",
            "is_on, dwc->pullups_connected",
        ).replace("\tdev_dbg(", "\t\tdev_dbg(")
        + "\t\tpm_runtime_put(dwc->dev);\n"
        "\t\treturn 0;\n"
        "\t}\n",
    ),
    (
        "PULLUP soft",
        "\tif (!is_on)\n"
        "\t\tret = dwc3_gadget_soft_disconnect(dwc);\n"
        "\telse\n"
        "\t\tret = dwc3_gadget_soft_connect(dwc);\n"
        "\n"
        "\tpm_runtime_put(dwc->dev);\n",
        "\tif (!is_on)\n"
        "\t\tret = dwc3_gadget_soft_disconnect(dwc);\n"
        "\telse\n"
        "\t\tret = dwc3_gadget_soft_connect(dwc);\n"
        "\n"
        "\tpm_runtime_put(dwc->dev);\n"
        + line(
            "PULLUP soft: is_on=%d ret=%d pullups=%d",
            "is_on, ret, dwc->pullups_connected",
        ),
    ),
    (
        "SOFTCONNECT enter",
        "static int dwc3_gadget_soft_connect(struct dwc3 *dwc)\n{\n"
        "\tint ret;\n",
        "static int dwc3_gadget_soft_connect(struct dwc3 *dwc)\n{\n"
        "\tint ret;\n"
        + line(
            "SOFTCONNECT enter: pullups=%d connected=%d state=%d",
            "dwc->pullups_connected, dwc->connected, dwc->gadget->state",
        ),
    ),
    (
        "SOFTCONNECT reset",
        "\tret = dwc3_core_soft_reset(dwc);\n"
        "\tif (ret)\n"
        "\t\treturn ret;\n",
        "\tret = dwc3_core_soft_reset(dwc);\n"
        + line("SOFTCONNECT reset: ret=%d", "ret")
        + "\tif (ret)\n"
        "\t\treturn ret;\n",
    ),
    (
        "SOFTCONNECT done",
        "\tdwc3_event_buffers_setup(dwc);\n"
        "\t__dwc3_gadget_start(dwc);\n"
        "\treturn dwc3_gadget_run_stop(dwc, true);\n"
        "}\n",
        "\tdwc3_event_buffers_setup(dwc);\n"
        "\t__dwc3_gadget_start(dwc);\n"
        "\tret = dwc3_gadget_run_stop(dwc, true);\n"
        + line(
            "SOFTCONNECT done: ret=%d pullups=%d",
            "ret, dwc->pullups_connected",
        )
        + "\treturn ret;\n"
        "}\n",
    ),
]

udc_edits = [
    (
        "UDC connect out",
        "out:\n\ttrace_usb_gadget_connect(gadget, ret);\n",
        "out:\n"
        + ('\tdev_dbg(&gadget->dev, "' + PREFIX +
           "UDC connect out: connected=%d deactivated=%d allow_connect=%d "
           "started=%d has_pullup=%d ret=%d" + NL + '", ' +
           "gadget->connected, gadget->deactivated, "
           "gadget->udc->allow_connect, gadget->udc->started, "
           "gadget->ops->pullup != NULL, ret);\n")
        + "\ttrace_usb_gadget_connect(gadget, ret);\n",
    ),
]

n1 = inject("drivers/usb/dwc3/gadget.c", gadget_edits)
n2 = inject("drivers/usb/gadget/udc/core.c", udc_edits)
print("Applied RG353PS DWC3 RECONNECT low-frequency diagnostics")
