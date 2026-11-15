#!/bin/sh
# Regression checks for the RG353PS diagnostic/selector UI process handoff.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL="$ROOT/platforms/rg353ps/src/rg353ps-control-center.c"
SELECTOR="$ROOT/platforms/rg353ps/src/rg353ps-frontend-selector.c"
UI="$ROOT/src/rg353ps-ui.h"
BUILDER="$ROOT/platforms/rg353ps/build-rootfs.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$CONTROL" "$SELECTOR" <<'PY'
import sys
from pathlib import Path

control, selector = (Path(p).read_text() for p in sys.argv[1:])

def check_handoff(source, fn, end_fn, label):
    start = source.find(fn)
    end = source.find(end_fn, start + len(fn))
    if start < 0 or end < 0:
        raise SystemExit("FAIL: missing " + label + " function boundary")
    body = source[start:end]
    close = body.find("close_inputs();")
    fork = body.find("child = fork();")
    wait = body.find("waitpid(child, &status, 0)")
    reopen = body.rfind("discover_inputs();")
    if min(close, fork, wait, reopen) < 0 or not close < fork < wait < reopen:
        raise SystemExit("FAIL: incorrect evdev handoff in " + label)

check_handoff(control, "static void open_frontend_selector(void)",
              "static void request_usb_storage", "diagnostics -> selector")
check_handoff(selector, "static void open_diagnostics(void)",
              "static void choose_launch", "selector -> diagnostics")

assert "return entry_count + 2;" in selector, "selector must always show diagnostics/return and language rows"
assert "static int count_package_profiles(const char *package_id)" in selector, "uninstall confirmation lost its profile-count helper"
assert "static int return_to_diagnostics;" in selector
assert "if (return_to_diagnostics)" in selector, "nested selector must return to its diagnostics parent"
assert "show_diagnostics_entry" not in selector, "diagnostics row must not disappear in nested selector"
assert "case 7:" in control and "baseos_ui_toggle_language()" in control
assert "case 8:" in control, "nested diagnostics must retain the explicit return action"
assert "baseos_ui_toggle_language()" in selector, "selector language row must be interactive"
assert "baseos_ui_load_language();" in control, "diagnostic parent does not reload language changed by nested selector"
assert "baseos_ui_load_language();" in selector, "selector parent does not reload language changed by diagnostics"
assert "baseos_language_zh" not in control, "unknown language-state symbol"
assert "baseos_ui_init();" in control and "baseos_ui_init();" in selector
assert '#include <rg353ps-ui.h>' in control and '#include <rg353ps-ui.h>' in selector
print("PASS: console UI input ownership, return path and bilingual controls")
PY

grep -Fq 'python3 py3-pillow font-wqy-zenhei kbd' "$BUILDER" ||
  fail "build container does not include Pillow and WenQuanYi font sources"
grep -Fq 'exfatprogs kbd' "$BUILDER" ||
  fail "target rootfs does not include setfont"
grep -Fq 'baseos-cjk-18x20.psf' "$BUILDER" ||
  fail "compact CJK console font is not generated"
grep -Fq '"$REPO_ROOT/tools":/baseos-tools:ro' "$BUILDER" ||
  fail "font generator tools directory is not mounted into the build container"
grep -Fq 'python3 /baseos-tools/mkconsolefont.py' "$BUILDER" ||
  fail "rootfs builder does not run the font generator from the mounted tools directory"
grep -Fq -- '--source /baseos-src/rg353ps-ui.h' "$BUILDER" ||
  fail "shared language labels are missing from the generated font"
grep -Fq 'test -x "$R/usr/sbin/setfont"' "$BUILDER" ||
  fail "rootfs build does not verify the setfont executable"
grep -Fq -- '-I/baseos-src' "$BUILDER" ||
  fail "BaseOS shared UI header is not included when compiling terminal UIs"
grep -Fq 'vt.default_utf8=1' "$ROOT/platforms/rg353ps/build-image.sh" ||
  fail "Linux text console is not explicitly configured for UTF-8"
grep -Fq 'ui_language=' "$UI" ||
  fail "language preference is not persisted"

grep -Fq "psfaddtable" "$BUILDER" ||
  fail "font Unicode map is not produced with kbd psfaddtable"
grep -Fq 'psfgettable "$FINAL_FONT" "$FONT_TABLE_CHECK"' "$BUILDER" ||
  fail "generated font Unicode map is not round-trip verified"
grep -Fq "U+{ord(ch):04X}" "$ROOT/tools/mkconsolefont.py" ||
  fail "font mapping table does not use kbd U+ Unicode syntax"
grep -Fq "ASCII space must map to native glyph slot 32" "$BUILDER" ||
  fail "ASCII space does not retain its native glyph position"
grep -Fq "ASCII @ must map to native glyph slot 64" "$BUILDER" ||
  fail "ASCII @ does not retain its native glyph position"
grep -Fq "ASCII A must map to native glyph slot 65" "$BUILDER" ||
  fail "ASCII letters do not retain their native glyph positions"
grep -Fq "Chinese glyph U+4E2D bitmap is empty" "$BUILDER" ||
  fail "font validator does not verify an actual Chinese glyph bitmap"
grep -Fq "ASCII space bitmap must be blank" "$BUILDER" ||
  fail "font validator does not verify blank-space glyph bitmap"
grep -Fq "CJK_SLOTS = tuple(range(0, 32)) + tuple(range(127, GLYPH_COUNT))" "$ROOT/tools/mkconsolefont.py" ||
  fail "font generator does not reserve native ASCII code positions"
grep -Fq "GLYPH_COUNT = 256" "$ROOT/tools/mkconsolefont.py" ||
  fail "console font must remain in 256-glyph mode"
grep -Fq 'L1/R1: shoulder buttons' "$CONTROL" ||
  fail "button help page does not explain L1/R1 shoulder buttons"
grep -Fq 'L1/R1：左/右肩键' "$CONTROL" ||
  fail "Chinese button help page is missing L1/R1 shoulder buttons"
grep -Fq 'case BTN_TL: return "L1 / TL";' "$CONTROL" ||
  fail "L1 input event is not named"
grep -Fq 'case BTN_TR: return "R1 / TR";' "$CONTROL" ||
  fail "R1 input event is not named"
grep -Fq 'L1/R1：肩键输入' "$CONTROL" ||
  fail "controller test page does not explain L1/R1 input feedback"

grep -Fq '\033%%G\033[2J' "$CONTROL" ||
  fail "diagnostics does not force UTF-8 mode on Linux console redraw"
grep -Fq '\033%%G\033[2J' "$SELECTOR" ||
  fail "frontend selector does not force UTF-8 mode on Linux console redraw"

echo "PASS: RG353PS UI navigation and native ASCII/CJK console font contract"
