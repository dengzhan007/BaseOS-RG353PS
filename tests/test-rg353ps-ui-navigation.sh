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

def check_handoff(source, fn, label):
    start = source.find(fn)
    if start < 0:
        raise SystemExit("FAIL: missing " + label + " function")
    body = source[start:]
    close = body.find("close_inputs();")
    fork = body.find("child = fork();")
    wait = body.find("waitpid(child, &status, 0)")
    reopen = body.rfind("discover_inputs();")
    if min(close, fork, wait, reopen) < 0 or not close < fork < wait < reopen:
        raise SystemExit("FAIL: incorrect evdev handoff in " + label)

check_handoff(control, "static void open_frontend_selector(void)", "diagnostics -> selector")
check_handoff(selector, "static void open_diagnostics(void)", "selector -> diagnostics")

assert "return entry_count + 2;" in selector, "selector must always show diagnostics/return and language rows"
assert "static int return_to_diagnostics;" in selector
assert "if (return_to_diagnostics)" in selector, "nested selector must return to its diagnostics parent"
assert "show_diagnostics_entry" not in selector, "diagnostics row must not disappear in nested selector"
assert "case 7:" in control and "baseos_ui_toggle_language()" in control
assert "case 8:" in control, "nested diagnostics must retain the explicit return action"
assert "baseos_ui_toggle_language()" in selector, "selector language row must be interactive"
assert "baseos_ui_init();" in control and "baseos_ui_init();" in selector
assert '#include <rg353ps-ui.h>' in control and '#include <rg353ps-ui.h>' in selector
print("PASS: console UI input ownership, return path and bilingual controls")
PY

grep -Fq 'python3 py3-pillow font-wqy-zenhei' "$BUILDER" ||
  fail "build container does not include Pillow and WenQuanYi font sources"
grep -Fq 'exfatprogs kbd' "$BUILDER" ||
  fail "target rootfs does not include setfont"
grep -Fq 'baseos-cjk-16.psf' "$BUILDER" ||
  fail "compact CJK console font is not generated"
grep -Fq -- '-I/baseos-src' "$BUILDER" ||
  fail "BaseOS shared UI header is not included when compiling terminal UIs"
grep -Fq 'ui_language=' "$UI" ||
  fail "language preference is not persisted"

echo "PASS: RG353PS UI navigation and CJK font build contract"
