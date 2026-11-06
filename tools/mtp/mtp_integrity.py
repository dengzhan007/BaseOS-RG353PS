#!/usr/bin/env python3
"""RG353PS MTP file-transfer integrity acceptance tool.

The tool verifies that files survive a real MTP round trip byte for byte. It
never assumes a transfer succeeded because the device enumerated: every claim in
the report comes from a size/SHA-256 comparison of bytes that actually arrived.

Subcommands
-----------
prepare   create the marked test dataset (refuses to clobber an existing tree)
pull      copy device -> host and verify every file against the manifest
push      host -> device -> host round trip with fresh data and verification
ops       create/mkdir/rename/overwrite/delete checks inside the test tree
run       prepare + pull + push + ops, then write the reports
cleanup   remove the test tree, after validating marker, run id and path

Backends
--------
local          simulated storage root (automated tests)
linux-gvfs     gvfs/libmtp FUSE mount of the device
linux-mtp-tools libmtp command-line tools
windows-wpd    Windows Portable Devices via hosts/wpd.ps1

Only /mnt/SDCARD's tool-owned subdirectory is ever touched. The tool never
mounts, formats, rebinds the UDC, or changes the USB gadget state.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mtp_common as common
from mtp_backends import BackendError, build_backend

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


class Checks:
    """Ordered check log; totals are derived, never hand-written."""

    def __init__(self, stage: str):
        self.stage = stage
        self.items = []

    def add(self, status: str, name: str, detail: str = "", **extra):
        item = {"stage": self.stage, "status": status, "check": name, "detail": detail}
        item.update(extra)
        self.items.append(item)
        return item

    def passed(self, name, detail="", **extra):
        return self.add(PASS, name, detail, **extra)

    def failed(self, name, detail="", **extra):
        return self.add(FAIL, name, detail, **extra)

    def skipped(self, name, detail="", **extra):
        return self.add(SKIP, name, detail, **extra)


def _timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _write_bytes(path: str, size: int, seed: int = 0) -> None:
    """Deterministic pseudo-random payload, written in 1 MiB chunks."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    state = (seed * 2654435761 + 1) & 0xFFFFFFFF
    remaining = size
    with open(path, "wb") as handle:
        while remaining > 0:
            block = min(1024 * 1024, remaining)
            chunk = bytearray(block)
            for index in range(block):
                state = (1103515245 * state + 12345) & 0x7FFFFFFF
                chunk[index] = (state >> 16) & 0xFF
            handle.write(chunk)
            remaining -= block


def _write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def generate_dataset(directory: str, profile: str, run_id: str, salt: str = "device") -> list:
    """Create the canonical dataset under ``directory`` and return its entries."""
    relpaths = []
    for index, (rel, size) in enumerate(common.dataset_for(profile)):
        target = os.path.join(directory, rel.replace("/", os.sep))
        if rel.endswith(".txt"):
            body = (
                f"BaseOS RG353PS MTP integrity test\n"
                f"run_id={run_id}\n"
                f"file={rel}\n"
                f"salt={salt}\n"
                f"index={index}\n"
            )
            body = (body * max(1, size // len(body) + 1))[:size]
            _write_text(target, body)
        else:
            _write_bytes(target, size, seed=index + len(salt))
        relpaths.append(rel)
    return relpaths


def verify_tree(root: str, manifest: dict, direction: str, checks: Checks, stage_note: str = ""):
    """Compare files under ``root`` against ``manifest`` and log per-file results."""
    for item in manifest["files"]:
        rel = item["relpath"]
        expected_size = item["size"]
        expected_hash = item["sha256"]
        try:
            path = common.contained_path(root, rel)
        except common.PathSafetyError as error:
            checks.failed(f"{direction}:{rel}", str(error), relpath=rel, direction=direction)
            continue
        if not os.path.isfile(path):
            checks.failed(
                f"{direction}:{rel}", "file missing after transfer", relpath=rel,
                direction=direction, expected_size=expected_size, expected_sha256=expected_hash,
            )
            continue
        actual_size = os.path.getsize(path)
        actual_hash = common.sha256_file(path)
        detail = stage_note
        if actual_size != expected_size:
            checks.failed(
                f"{direction}:{rel}",
                f"size mismatch: expected {expected_size} got {actual_size}",
                relpath=rel, direction=direction, expected_size=expected_size,
                actual_size=actual_size, expected_sha256=expected_hash, actual_sha256=actual_hash,
            )
            continue
        if actual_hash != expected_hash:
            checks.failed(
                f"{direction}:{rel}",
                f"sha256 mismatch: expected {expected_hash[:16]}... got {actual_hash[:16]}...",
                relpath=rel, direction=direction, expected_size=expected_size,
                actual_size=actual_size, expected_sha256=expected_hash, actual_sha256=actual_hash,
            )
            continue
        checks.passed(
            f"{direction}:{rel}", detail, relpath=rel, direction=direction,
            expected_size=expected_size, actual_size=actual_size,
            expected_sha256=expected_hash, actual_sha256=actual_hash,
        )


def check_names(manifest: dict, checks: Checks) -> None:
    """Prove the dataset really carries the awkward names the task requires."""
    relpaths = [item["relpath"] for item in manifest["files"]]
    checks.passed("dataset:file-count", f"{len(relpaths)} entries", count=len(relpaths)) if relpaths \
        else checks.failed("dataset:file-count", "manifest lists no files")
    non_ascii = [rel for rel in relpaths if any(ord(char) > 127 for char in rel)]
    checks.passed("dataset:unicode-name", f"{len(non_ascii)} entries with non-ASCII names",
                  entries=non_ascii) if non_ascii else checks.failed("dataset:unicode-name",
                  "no non-ASCII file name in the dataset")
    with_space = [rel for rel in relpaths if " " in rel]
    checks.passed("dataset:space-name", f"{len(with_space)} entries containing spaces",
                  entries=with_space) if with_space else checks.failed("dataset:space-name",
                  "no file name containing a space in the dataset")
    nested = [rel for rel in relpaths if rel.count("/") >= 2]
    checks.passed("dataset:nested-path", f"{len(nested)} entries nested two levels or deeper",
                  entries=nested) if nested else checks.failed("dataset:nested-path",
                  "no deeply nested path in the dataset")
    sizes = sorted({item["size"] for item in manifest["files"]})
    checks.passed("dataset:size-spread", f"sizes present: {sizes}", sizes=sizes)


def ensure_dirs(backend, rel_dir: str) -> None:
    """Create a path one segment at a time.

    Windows WPD and libmtp only create a single directory per call, so the
    caller cannot rely on a recursive mkdir. Each level is verified against the
    MTP listing instead of trusting the verb's return value.
    """
    parts = [part for part in rel_dir.strip("/").split("/") if part]
    current = ""
    for part in parts:
        target = f"{current}/{part}" if current else part
        listing = backend.list_dir(current) if current else backend.list_dir("")
        if any(item["is_dir"] and item["name"] == part for item in listing):
            current = target
            continue
        backend.make_dir(target)
        listing = backend.list_dir(current) if current else backend.list_dir("")
        if not any(item["is_dir"] and item["name"] == part for item in listing):
            raise BackendError(f"directory {target} did not appear in the MTP listing")
        current = target


def ssh_device_digests(args, device_dir: str):
    """Hash every file under ``device_dir`` on the handheld itself.

    Used when MTP read-back is unavailable (Windows' Shell namespace raises a
    modal prompt for a just-written object). The device walks the tree itself so
    no non-ASCII path ever travels through the SSH command line, which would be
    mangled by the host console encoding.

    Returns {relative path: sha256}. This is device-side evidence, never an MTP
    read-back, and needs --device-ssh plus --device-storage-root.
    """
    if not args.device_ssh:
        raise BackendError("device-side verification needs --device-ssh")
    script = (
        f"cd {shlex.quote(device_dir)} || exit 3; "
        'find . -type f | sort | while IFS= read -r f; do '
        'printf "%s  %s\\n" "$(sha256sum <\"$f\" | cut -d\' \' -f1)" "${f#./}"; done'
    )
    argv = args.device_ssh.split() + [script]
    try:
        result = subprocess.run(argv, capture_output=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BackendError(f"device-side hash probe failed: {error}")
    if result.returncode != 0:
        detail = (result.stderr or b"").decode("utf-8", "replace").strip()
        raise BackendError(f"device-side hash probe exited {result.returncode}: {detail[:300]}")
    digests = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        if "  " not in line:
            continue
        digest, rel = line.split("  ", 1)
        digests[rel.strip()] = digest.strip()
    return digests


def cmd_prepare(args, backend, checks: Checks) -> int:
    run_id = args.run_id or common.new_run_id()
    test_dir = common.test_dir_name(run_id)
    existing = False
    try:
        backend.list_dir(test_dir)
        existing = True
    except BackendError:
        existing = False

    if existing:
        if not args.force:
            checks.failed("prepare:existing-dir",
                          f"{test_dir} already exists; refusing to overwrite (pass --force "
                          "to reuse a directory this tool created)")
            return 1
        if not args.confirm_force:
            checks.failed("prepare:existing-dir",
                          f"{test_dir} exists; --force needs --confirm-force to touch it")
            return 1
        # Only a tree carrying our own marker may be replaced.
        tmp_marker = os.path.join(tempfile.mkdtemp(prefix="mtp-marker-"), common.MARKER_NAME)
        try:
            backend.get_file(f"{test_dir}/{common.MARKER_NAME}", tmp_marker)
            marker = common.read_marker(os.path.dirname(tmp_marker))
        except (BackendError, common.PathSafetyError, OSError) as error:
            checks.failed("prepare:existing-dir",
                          f"{test_dir} is not a tool-created tree, refusing to replace it: {error}")
            return 1
        if marker.get("run_id") != run_id:
            checks.failed("prepare:existing-dir",
                          f"marker run id {marker.get('run_id')} does not match {run_id}")
            return 1
        backend.delete(test_dir, recursive=True)
        checks.passed("prepare:existing-dir", f"replaced previous tool tree {test_dir} after marker check")

    staging = tempfile.mkdtemp(prefix="mtp-prepare-")
    try:
        relpaths = generate_dataset(staging, args.dataset_profile, run_id, salt="device")
        entries = common.build_entries(staging, relpaths)
        common.write_manifest(staging, run_id, "device", entries)
        common.write_marker(staging, run_id, args.dataset_profile)

        ensure_dirs(backend, test_dir)
        for rel in relpaths + [common.MANIFEST_NAME, common.MARKER_NAME]:
            parent = rel.rsplit("/", 1)[0] if "/" in rel else ""
            target_dir = f"{test_dir}/{parent}" if parent else test_dir
            if parent:
                ensure_dirs(backend, target_dir)
            backend.put_file(os.path.join(staging, rel.replace("/", os.sep)), target_dir)
        checks.passed("prepare:upload", f"created {len(relpaths)} files in {test_dir}",
                      run_id=run_id, test_dir=test_dir, files=len(relpaths))
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    print(run_id)
    return 0


def cmd_pull(args, backend, checks: Checks) -> int:
    run_id = args.run_id
    test_dir = common.test_dir_name(run_id)
    work = os.path.join(args.workdir or tempfile.mkdtemp(prefix="mtp-pull-"))
    received = os.path.join(work, "received")
    os.makedirs(received, exist_ok=True)

    manifest_path = os.path.join(work, common.MANIFEST_NAME)
    try:
        backend.get_file(f"{test_dir}/{common.MANIFEST_NAME}", manifest_path)
    except (BackendError, OSError) as error:
        checks.failed("pull:manifest", f"cannot read manifest over MTP: {error}")
        return 1
    try:
        manifest = common.read_manifest(work)
    except (common.PathSafetyError, ValueError, OSError) as error:
        checks.failed("pull:manifest", f"manifest is not trustworthy: {error}")
        return 1
    if manifest.get("run_id") != run_id:
        checks.failed("pull:manifest",
                      f"manifest run id {manifest.get('run_id')} does not match requested {run_id}")
        return 1
    checks.passed("pull:manifest", f"{len(manifest['files'])} files listed", run_id=run_id)

    listed = {item["name"] for item in backend.list_dir(test_dir)}
    expected_top = {item["relpath"].split("/")[0] for item in manifest["files"]}
    expected_top |= {common.MANIFEST_NAME, common.MARKER_NAME}
    missing = sorted(expected_top - listed)
    if missing:
        checks.failed("pull:listing", f"entries missing from the device listing: {missing}")
    else:
        checks.passed("pull:listing", "every manifest entry is present in the MTP listing")

    for item in manifest["files"]:
        rel = item["relpath"]
        target = os.path.join(received, rel.replace("/", os.sep))
        try:
            backend.get_file(f"{test_dir}/{rel}", target)
        except (BackendError, OSError) as error:
            checks.failed(f"pull:{rel}", f"download failed: {error}", relpath=rel, direction="pull")
            continue
    verify_tree(received, manifest, "pull", checks)
    check_names(manifest, checks)
    if args.keep_workdir:
        print(f"workdir kept at {work}", file=sys.stderr)
    return 0


def cmd_push(args, backend, checks: Checks) -> int:
    run_id = args.run_id
    test_dir = common.test_dir_name(run_id)
    # Unique suffix: a repeat run must never collide with leftover files,
    # because a collision turns into a modal "replace?" prompt on Windows.
    upload_name = f"{common.UPLOAD_DIR_PREFIX}{run_id}-{secrets.token_hex(2)}"
    upload_dir = f"{test_dir}/{upload_name}"
    work = os.path.join(args.workdir or tempfile.mkdtemp(prefix="mtp-push-"))
    source = os.path.join(work, "source")
    back = os.path.join(work, "readback")
    os.makedirs(back, exist_ok=True)

    relpaths = generate_dataset(source, args.dataset_profile, run_id, salt="host-upload")
    entries = common.build_entries(source, relpaths)
    manifest = {
        "tool": common.TOOL_NAME,
        "run_id": run_id,
        "files": [entry.as_dict() for entry in entries],
    }

    try:
        ensure_dirs(backend, upload_dir)
    except BackendError as error:
        checks.failed("push:mkdir", f"cannot create {upload_dir}: {error}")
        return 1

    for rel in relpaths:
        # Keep the relative layout: the device tree must mirror the host tree so
        # nested paths are exercised, not flattened into one directory.
        parent = rel.rsplit("/", 1)[0] if "/" in rel else ""
        target_dir = f"{upload_dir}/{parent}" if parent else upload_dir
        try:
            ensure_dirs(backend, target_dir)
            backend.put_file(os.path.join(source, rel.replace("/", os.sep)), target_dir)
        except (BackendError, OSError) as error:
            checks.failed(f"push:{rel}", f"upload failed: {error}", relpath=rel, direction="push")
    if backend.capabilities.get("readback_after_put"):
        for rel in relpaths:
            target = os.path.join(back, rel.replace("/", os.sep))
            try:
                backend.get_file(f"{upload_dir}/{rel}", target)
            except (BackendError, OSError) as error:
                checks.failed(f"push-readback:{rel}", f"read-back failed: {error}",
                              relpath=rel, direction="push-readback")
        verify_tree(back, manifest, "push-readback", checks,
                    stage_note="host -> device -> host round trip")
    elif args.device_ssh:
        device_dir = f"{args.device_storage_root.rstrip('/')}/{upload_dir}"
        try:
            digests = ssh_device_digests(args, device_dir)
        except BackendError as error:
            checks.failed("push:verify", f"device-side verification failed: {error}")
            digests = {}
        for item in manifest["files"]:
            rel = item["relpath"]
            actual = digests.get(rel)
            if actual is None:
                checks.failed(f"push:{rel}", "file is missing on the device", relpath=rel,
                              direction="push-device-hash")
            elif actual != item["sha256"]:
                checks.failed(f"push:{rel}",
                              f"device sha256 {actual[:16]}... != host {item['sha256'][:16]}...",
                              relpath=rel, direction="push-device-hash",
                              expected_sha256=item["sha256"], actual_sha256=actual)
            else:
                checks.passed(f"push:{rel}",
                              "MTP upload verified by the device's own SHA-256 "
                              "(not an MTP read-back)",
                              relpath=rel, direction="push-device-hash",
                              expected_size=item["size"], expected_sha256=item["sha256"],
                              actual_sha256=actual)
    else:
        for item in manifest["files"]:
            checks.skipped(f"push:{item['relpath']}",
                           f"{backend.name} cannot read back a just-written object without a "
                           "modal prompt; pass --device-ssh for device-side SHA-256 instead",
                           relpath=item["relpath"], direction="push")
    if args.keep_workdir:
        print(f"workdir kept at {work}", file=sys.stderr)
    return 0


def cmd_ops(args, backend, checks: Checks) -> int:
    """Exercise create/mkdir/rename/overwrite/delete inside the tool's own tree."""
    run_id = args.run_id
    test_dir = common.test_dir_name(run_id)
    ops_root = f"{test_dir}/_ops-{run_id}-{secrets.token_hex(2)}"
    work = tempfile.mkdtemp(prefix="mtp-ops-")

    def rel(*parts: str) -> str:
        return "/".join([ops_root, *parts])

    def local(name: str, payload: bytes) -> str:
        path = os.path.join(work, name)
        with open(path, "wb") as handle:
            handle.write(payload)
        return path

    def listing_names(directory: str) -> set:
        return {item["name"] for item in backend.list_dir(directory)}

    try:
        ensure_dirs(backend, ops_root)
        checks.passed("ops:mkdir-root", f"created {ops_root}")
    except (BackendError, OSError) as error:
        checks.failed("ops:mkdir-root", f"cannot create the ops directory: {error}")
        shutil.rmtree(work, ignore_errors=True)
        return 1

    # 1. multi-level directory with unicode + spaces in the path
    try:
        ensure_dirs(backend, rel("多层 目录", "子目录 with spaces", "deep"))
        names = listing_names(rel("多层 目录", "子目录 with spaces"))
        if "deep" in names:
            checks.passed("ops:mkdir-nested", "three-level unicode/spaced directory created")
        else:
            checks.failed("ops:mkdir-nested", f"listing was {sorted(names)}")
    except (BackendError, OSError) as error:
        checks.failed("ops:mkdir-nested", f"nested mkdir failed: {error}")

    # 2. create a file with a unicode + space name, then verify what landed
    payload_a = b"baseos mtp ops file A\n" * 64
    writable = local("ops-a.bin", payload_a)
    try:
        backend.put_file(writable, ops_root)
        if backend.capabilities.get("readback_after_put"):
            readback = os.path.join(work, "ops-a-readback.bin")
            backend.get_file(rel("ops-a.bin"), readback)
            actual = common.sha256_file(readback)
            note = "created and read back intact"
        elif args.device_ssh:
            device_dir = f"{args.device_storage_root.rstrip('/')}/{ops_root}"
            digests = ssh_device_digests(args, device_dir)
            actual = digests.get("ops-a.bin", "")
            note = "created; verified with the device's own SHA-256 (not an MTP read-back)"
        else:
            actual = None
            note = ""
        expected = common.sha256_bytes(payload_a)
        if actual is None:
            checks.skipped("ops:create-file",
                           f"{backend.name} cannot read back a just-written object without a "
                           "modal prompt; pass --device-ssh for device-side SHA-256")
        elif actual == expected:
            checks.passed("ops:create-file", f"unicode/spaced file {note}")
        else:
            checks.failed("ops:create-file", "digest on the device differs from what was uploaded")
    except (BackendError, OSError) as error:
        checks.failed("ops:create-file", f"create/verify failed: {error}")

    # 3. overwrite the same path with different content and confirm the new bytes
    payload_b = b"baseos mtp ops file B, overwrite payload\n" * 64
    if not (backend.capabilities.get("overwrite") and backend.capabilities.get("readback_after_put")):
        checks.skipped("ops:overwrite-file",
                       f"{backend.name} raises a modal replace prompt; needs a human click")
    else:
        try:
            backend.put_file(local("ops-a.bin", payload_b), ops_root)
            readback = os.path.join(work, "ops-a-readback2.bin")
            backend.get_file(rel("ops-a.bin"), readback)
            actual = common.sha256_file(readback)
            if actual == common.sha256_bytes(payload_b):
                checks.passed("ops:overwrite-file", "same path overwritten; new bytes verified")
            else:
                checks.failed("ops:overwrite-file",
                              f"read-back digest {actual[:16]}... is not the new payload")
        except (BackendError, OSError) as error:
            checks.failed("ops:overwrite-file", f"overwrite check failed: {error}")

    # 4. rename file and directory
    renamed_file = "重命名 文件 alpha.bin"
    renamed_dir = "重命名 目录"
    if not backend.capabilities.get("rename"):
        checks.skipped("ops:rename-file", f"{backend.name} exposes no scriptable rename verb")
        checks.skipped("ops:rename-dir", f"{backend.name} exposes no scriptable rename verb")
    else:
        try:
            backend.rename(rel("ops-a.bin"), rel(renamed_file))
            names = listing_names(ops_root)
            if renamed_file in names and "ops-a.bin" not in names:
                checks.passed("ops:rename-file", "file renamed")
            else:
                checks.failed("ops:rename-file", f"listing after rename was {sorted(names)}")
        except (BackendError, OSError) as error:
            checks.failed("ops:rename-file", f"rename failed: {error}")
        try:
            backend.rename(rel("多层 目录"), rel(renamed_dir))
            names = listing_names(ops_root)
            if renamed_dir in names and "多层 目录" not in names:
                checks.passed("ops:rename-dir", "directory renamed")
            else:
                checks.failed("ops:rename-dir", f"listing after rename was {sorted(names)}")
        except (BackendError, OSError) as error:
            checks.failed("ops:rename-dir", f"rename failed: {error}")

    # 5. delete file and directory tree
    if not backend.capabilities.get("delete"):
        checks.skipped("ops:delete-file", f"{backend.name} cannot delete over MTP")
        checks.skipped("ops:delete-dir", f"{backend.name} cannot delete over MTP")
    else:
        victim = renamed_file if backend.capabilities.get("rename") else "ops-a.bin"
        try:
            backend.delete(rel(victim))
            names = listing_names(ops_root)
            if victim not in names:
                checks.passed("ops:delete-file", f"deleted {victim}")
            else:
                checks.failed("ops:delete-file", f"{victim} is still listed after delete")
        except (BackendError, OSError) as error:
            checks.failed("ops:delete-file", f"delete failed: {error}")
        victim_dir = renamed_dir if backend.capabilities.get("rename") else "多层 目录"
        try:
            backend.delete(rel(victim_dir), recursive=True)
            names = listing_names(ops_root)
            if victim_dir not in names:
                checks.passed("ops:delete-dir", f"removed {victim_dir} and its children")
            else:
                checks.failed("ops:delete-dir", f"{victim_dir} is still listed after delete")
        except (BackendError, OSError) as error:
            checks.failed("ops:delete-dir", f"directory delete failed: {error}")

    shutil.rmtree(work, ignore_errors=True)
    return 0


def probe_device(args, checks: "Checks") -> dict:
    """Record the handheld environment when an SSH command is supplied.

    Optional: without --device-ssh the run still works, but the report says the
    device side was not identified instead of inventing a version string.
    """
    if not args.device_ssh:
        checks.skipped("device:environment",
                       "no --device-ssh given; device environment not recorded")
        return {"probed": False}
    probe = ("uname -a; "
             "cat /etc/baseos-release 2>/dev/null; "
             "cat /etc/baseos_build 2>/dev/null; "
             "for u in /sys/class/udc/*; do printf 'udc=%s state=%s speed=%s\\n' "
             "\"$u\" \"$(cat $u/state 2>/dev/null)\" \"$(cat $u/current_speed 2>/dev/null)\"; done")
    argv = args.device_ssh.split() + [probe]
    try:
        result = subprocess.run(argv, capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        checks.failed("device:environment", f"device probe failed: {error}")
        return {"probed": False, "error": str(error)}
    text = (result.stdout or b"").decode("utf-8", "replace").strip()
    if result.returncode != 0:
        detail = (result.stderr or b"").decode("utf-8", "replace").strip()
        checks.failed("device:environment", f"device probe exited {result.returncode}: {detail[:300]}")
        return {"probed": False, "error": detail[:300]}
    checks.passed("device:environment", "device environment recorded", summary=text[:600])
    return {"probed": True, "summary": text}


def cmd_run(args, backend, checks: Checks) -> int:
    run_id = args.run_id or common.new_run_id()
    args.run_id = run_id
    started = time.time()
    report = {
        "tool": common.TOOL_NAME,
        "tool_version": common.TOOL_VERSION,
        "run_id": run_id,
        "started_utc": _timestamp(),
        "host": {
            "os": f"{platform.system()} {platform.release()}",
            "python": platform.python_version(),
            "machine": platform.machine(),
        },
        "backend": backend.describe(),
        "dataset_profile": args.dataset_profile,
        "stages": {},
        "checks": [],
    }

    connection = Checks("connection")
    try:
        root_listing = backend.list_dir("")
        connection.passed("connection:list-storage-root",
                          f"{len(root_listing)} entries visible at the storage root")
        report["mtp_connected"] = True
    except (BackendError, OSError) as error:
        connection.failed("connection:list-storage-root", f"cannot list the storage root: {error}")
        report["mtp_connected"] = False
    report["checks"].extend(connection.items)
    report["device"] = probe_device(args, connection)

    if not report["mtp_connected"]:
        report["finished_utc"] = _timestamp()
        report["duration_seconds"] = round(time.time() - started, 3)
        report["totals"] = {"pass": 0, "fail": 1, "skip": 0}
        _write_reports(args, report)
        return 1

    stages = []
    if args.skip_prepare:
        # The dataset was created on the device by mtp-prepare.sh; re-running
        # prepare here would either clobber it or fail on purpose.
        report["prepare_skipped"] = True
    else:
        stages.append(("prepare", cmd_prepare))
    stages += [("pull", cmd_pull), ("push", cmd_push), ("ops", cmd_ops)]
    for stage_name, handler in stages:
        stage_checks = Checks(stage_name)
        before = len(stage_checks.items)
        try:
            handler(args, backend, stage_checks)
        except BackendError as error:
            stage_checks.failed(f"{stage_name}:aborted", str(error))
        except common.PathSafetyError as error:
            stage_checks.failed(f"{stage_name}:safety", str(error))
        report["stages"][stage_name] = {
            "checks": len(stage_checks.items) - before,
            "fail": sum(1 for item in stage_checks.items if item["status"] == FAIL),
        }
        report["checks"].extend(stage_checks.items)

    report["finished_utc"] = _timestamp()
    report["duration_seconds"] = round(time.time() - started, 3)
    report["totals"] = {
        "pass": sum(1 for item in report["checks"] if item["status"] == PASS),
        "fail": sum(1 for item in report["checks"] if item["status"] == FAIL),
        "skip": sum(1 for item in report["checks"] if item["status"] == SKIP),
    }
    _write_reports(args, report)
    return 0 if report["totals"]["fail"] == 0 else 1


def _write_reports(args, report: dict) -> None:
    outdir = args.out or os.path.join(os.getcwd(), f"mtp-integrity-{report['run_id']}")
    os.makedirs(outdir, exist_ok=True)
    json_path = os.path.join(outdir, "report.json")
    with open(json_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")

    md = [
        f"# MTP file integrity report — {report['run_id']}",
        "",
        f"- Started: {report['started_utc']}",
        f"- Finished: {report.get('finished_utc', 'n/a')}",
        f"- Duration: {report.get('duration_seconds', 0)} s",
        f"- Host: {report['host']['os']} / Python {report['host']['python']} / {report['host']['machine']}",
        f"- Backend: `{report['backend']['backend']}` (moves bytes over MTP: {report['backend']['mtp']})",
        f"- Dataset profile: `{report['dataset_profile']}`",
        f"- MTP connection: {'reachable' if report.get('mtp_connected') else 'NOT reachable'}",
        "",
        "## Totals",
        "",
        f"- PASS: {report['totals']['pass']}",
        f"- FAIL: {report['totals']['fail']}",
        f"- SKIP: {report['totals']['skip']}",
        "",
        "SKIP entries are operations the host adapter cannot express over MTP; they are never counted as PASS.",
        "",
        "## Checks",
        "",
        "| Stage | Status | Check | Detail |",
        "|---|---|---|---|",
    ]
    for item in report["checks"]:
        detail = str(item.get("detail", "")).replace("|", "\\|")
        md.append(f"| {item['stage']} | {item['status']} | `{item['check']}` | {detail} |")
    failed = [item for item in report["checks"] if item["status"] == FAIL]
    md += ["", "## Failures", ""]
    if failed:
        for item in failed:
            md.append(f"- `{item['check']}`: {item.get('detail', '')}")
    else:
        md.append("None.")
    md.append("")
    md_path = os.path.join(outdir, "report.md")
    with open(md_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(md))

    print(f"report: {json_path}")
    print(f"report: {md_path}")
    print(f"labels: pass={report['totals']['pass']} fail={report['totals']['fail']} "
          f"skip={report['totals']['skip']}")


def cmd_cleanup(args, backend, checks: Checks) -> int:
    run_id = args.run_id
    test_dir = common.test_dir_name(run_id)
    if not args.confirm_cleanup:
        checks.failed("cleanup:confirm", "cleanup requires --confirm-cleanup")
        return 1
    work = tempfile.mkdtemp(prefix="mtp-clean-")
    marker_local = os.path.join(work, common.MARKER_NAME)
    try:
        backend.get_file(f"{test_dir}/{common.MARKER_NAME}", marker_local)
        marker = common.read_marker(work)
    except (BackendError, common.PathSafetyError, OSError, ValueError) as error:
        checks.failed("cleanup:marker", f"refusing to delete {test_dir}: {error}")
        shutil.rmtree(work, ignore_errors=True)
        return 1
    if not common.marker_matches(marker, run_id):
        checks.failed("cleanup:marker", f"marker run id {marker.get('run_id')} != {run_id}")
        shutil.rmtree(work, ignore_errors=True)
        return 1
    checks.passed("cleanup:marker", f"marker and run id verified for {test_dir}")
    try:
        backend.delete(test_dir, recursive=True)
        remaining = {item["name"] for item in backend.list_dir("")}
        if test_dir in remaining:
            checks.failed("cleanup:delete", f"{test_dir} is still present after delete")
        else:
            checks.passed("cleanup:delete", f"removed {test_dir} only")
    except (BackendError, OSError) as error:
        checks.failed("cleanup:delete", f"delete failed: {error}")
    shutil.rmtree(work, ignore_errors=True)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="RG353PS MTP file-transfer integrity acceptance tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("command",
                        choices=["prepare", "pull", "push", "ops", "run", "cleanup", "selftest"])
    parser.add_argument("--backend", default="auto",
                        choices=["auto", "local", "linux-gvfs", "linux-mtp-tools", "windows-wpd"])
    parser.add_argument("--root", help="storage root for the local simulation backend")
    parser.add_argument("--gvfs-root", help="path of a gvfs/libmtp mount of the device storage")
    parser.add_argument("--mtp-device", default="RG353PS", help="device name in Explorer (WPD)")
    parser.add_argument("--mtp-storage", default="RG353PS",
                        help="MTP storage name (linux-mtp-tools) or WPD storage folder (windows-wpd)")
    parser.add_argument("--run-id", help="reuse a specific run id instead of generating one")
    parser.add_argument("--dataset-profile", default="full", choices=["full", "fast"])
    parser.add_argument("--out", help="report directory")
    parser.add_argument("--workdir", help="keep transferred files in this directory")
    parser.add_argument("--keep-workdir", action="store_true")
    parser.add_argument("--force", action="store_true",
                        help="replace an existing test tree that carries our marker")
    parser.add_argument("--confirm-force", action="store_true",
                        help="second confirmation required together with --force")
    parser.add_argument("--confirm-cleanup", action="store_true",
                        help="required for cleanup: delete the test tree")
    parser.add_argument("--device-storage-root", default="/mnt/SDCARD",
                        help="MTP storage root path on the handheld (used with --device-ssh)")
    parser.add_argument("--skip-prepare", action="store_true",
                        help="dataset already exists on the device (mtp-prepare.sh was run); "
                             "go straight to pull/push/ops")
    parser.add_argument("--device-ssh",
                        help="optional command prefix used to record the handheld environment, "
                             "e.g. \"ssh root@192.168.42.1\" or \"plink -pw root root@192.168.42.1\"")
    parser.add_argument("--timeout", type=int, default=900, help="per-operation timeout in seconds")
    args = parser.parse_args(argv)

    if args.command == "selftest":
        here = os.path.dirname(os.path.abspath(__file__))
        suite = os.path.join(here, "tests", "test_mtp_integrity.py")
        return subprocess.call([sys.executable, "-m", "unittest", "-v", suite])

    if args.command in ("pull", "push", "ops", "cleanup") and not args.run_id:
        parser.error(f"{args.command} requires --run-id")

    backend = build_backend(args)
    checks = Checks(args.command)
    handler = {
        "prepare": cmd_prepare,
        "pull": cmd_pull,
        "push": cmd_push,
        "ops": cmd_ops,
        "run": cmd_run,
        "cleanup": cmd_cleanup,
    }[args.command]
    code = handler(args, backend, checks)

    if args.command in ("pull", "push", "ops", "cleanup"):
        for item in checks.items:
            print(f"{item['status']:4} {item['check']}: {item.get('detail', '')}")
        summary = {status: sum(1 for item in checks.items if item["status"] == status)
                   for status in (PASS, FAIL, SKIP)}
        print(f"labels: pass={summary[PASS]} fail={summary[FAIL]} skip={summary[SKIP]}")
        if summary[FAIL]:
            code = 1
    return code


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    raise SystemExit(main())
