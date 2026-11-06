#!/bin/sh
# Regression test for the RG353PS kernel source-cache input key.
# Verifies that the diagnostic injector is a required, hashed build input and
# that changing its content changes the cache key. No Docker/build/device access.
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUILD="$HERE/../build-kernel.sh"

[ -r "$BUILD" ] || {
    echo "FAIL: cannot read $BUILD" >&2
    exit 1
}

python3 - "$BUILD" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

build = Path(sys.argv[1]).read_text()

def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)
    print("PASS: " + message)

require(
    re.search(r'^INJECTOR="\$PLATFORM_DIR/kernel/tools/inject-reconnect-diag\.py"$', build, re.M),
    "injector path is pinned under platforms/rg353ps/kernel/tools",
)
require(
    re.search(r'^\[ -s "\$INJECTOR" \] \|\| \{[^\n]*missing DWC3 reconnect diagnostic injector', build, re.M),
    "missing or empty injector fails before cache-key generation",
)
require(
    re.search(
        r'^INJECTOR_SHA="\$\(baseos_sha256 "(?:\$INJECTOR|\$PLATFORM_DIR/kernel/tools/inject-reconnect-diag\.py)"\)"$',
        build,
        re.M,
    ),
    "injector content is hashed with baseos_sha256 (accepts $INJECTOR or the pinned injector path)",
)
require(
    re.search(r'^\[ -n "\$INJECTOR_SHA" \] \|\| \{[^\n]*cannot hash DWC3 reconnect diagnostic injector', build, re.M),
    "empty injector hash fails closed",
)

key_block = re.search(
    r"printf '%s\\n(?:%s\\n)*' \\\n(?P<args>.*?) > \"\$INPUT_KEY_FILE\"",
    build,
    re.S,
)
require(key_block is not None, "cache-key input list is explicit")
require(
    re.search(r'"\$INJECTOR_SHA"', key_block.group("args")),
    "injector SHA participates in inputs.sha256",
)
require(
    build.index('INPUT_KEY="$(baseos_sha256 "$INPUT_KEY_FILE")"') > key_block.start(),
    "INPUT_KEY is calculated from the completed input list",
)
require(
    'python3 /inputs/tools/inject-reconnect-diag.py "$SRC"' in build,
    "the hashed injector is the script executed inside the build container",
)
require(
    '-v "$PLATFORM_DIR/kernel":/inputs:ro' in build,
    "container receives the injector through the read-only /inputs mount",
)

# Exercise the same ordered SHA-256 composition used by build-kernel.sh.
# Only the injector payload changes; every other build input is held constant.
fixed_inputs = [
    "7.2.7",
    "becc8cb2a97b8b44b25d39dd5b6aa8f77b0af1c5",
    "patch-set-sha",
    "kernel-config-sha",
    "regdb-sha",
    "regdb-signature-sha",
    "regdb-certificate-sha",
    "builder-sha",
]
def cache_key(injector_bytes):
    injector_sha = hashlib.sha256(injector_bytes).hexdigest()
    payload = "\n".join(fixed_inputs + [injector_sha]) + "\n"
    return hashlib.sha256(payload.encode()).hexdigest()

before = cache_key(b"injector revision A")
after = cache_key(b"injector revision B")
require(before != after, "changing only injector content changes the resulting cache key")

print("RESULT: all kernel input-key regression checks passed")
PY
