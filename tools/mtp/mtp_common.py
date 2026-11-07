#!/usr/bin/env python3
"""Shared helpers for the RG353PS MTP file-integrity acceptance tool.

This module owns the pieces that must behave identically no matter which host
adapter (local simulation, Linux mtp-tools, Windows WPD) performs the transfer:

* the canonical test dataset layout and its sizes,
* SHA-256 / size manifests,
* the run-id and marker files used to recognise a directory this tool created,
* path-containment checks that refuse escapes and symlink hops.

Nothing here touches a device, a block device or the USB gadget state.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import time
from dataclasses import dataclass, asdict

TOOL_NAME = "baseos-mtp-integrity"
TOOL_VERSION = "1.0"
DATASET_VERSION = 1

MARKER_NAME = "baseos-mtp-test-marker.json"
MANIFEST_NAME = "baseos-mtp-test-manifest.json"
TEST_DIR_PREFIX = "baseos-mtp-test-"
UPLOAD_DIR_PREFIX = "_upload-"

RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")

# Relative paths are the contract between the device-side POSIX generator
# (device/mtp-prepare.sh) and this host tool. Changing one without the other
# breaks the manifest comparison, so the names and sizes live in one place.
DATASET_FULL = (
    ("small-4k.bin", 4 * 1024),
    ("medium-1m.bin", 1024 * 1024),
    ("large-128m.bin", 128 * 1024 * 1024),
    ("\u4e2d\u6587\u6587\u4ef6\u540d.txt", 1024),
    ("name with spaces.txt", 1024),
    ("\u4e2d\u6587 \u76ee\u5f55 with spaces/\u5d4c\u5957 \u5b50\u76ee\u5f55/\u6df1\u5c42 \u6587\u4ef6.txt", 1024),
    ("nested/sub/deep.bin", 64 * 1024),
)

# Same layout with the payload sizes shrunk so the automated suite stays fast.
# The integrity logic exercised is identical; only the byte counts differ.
DATASET_FAST = tuple(
    (name, min(size, 8192) if size >= 1024 * 1024 else size)
    for name, size in DATASET_FULL
)

DATASET_PROFILES = {"full": DATASET_FULL, "fast": DATASET_FAST}


class PathSafetyError(RuntimeError):
    """Raised when a path would leave the permitted MTP test root."""


def dataset_for(profile: str):
    try:
        return DATASET_PROFILES[profile]
    except KeyError:
        raise SystemExit(f"unknown dataset profile: {profile}")


def new_run_id() -> str:
    """Run ids are timestamped plus random so two sessions never collide."""
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    return f"{stamp}-{secrets.token_hex(3)}"


def test_dir_name(run_id: str) -> str:
    if not RUN_ID_RE.match(run_id or ""):
        raise SystemExit(f"invalid run id {run_id!r}; expected YYYYMMDD-HHMMSS-aaaaaa")
    return f"{TEST_DIR_PREFIX}{run_id}"


def sha256_file(path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(chunk_size)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def safe_relpath(rel: str) -> str:
    """Normalise a manifest-relative path and refuse anything that escapes."""
    if not isinstance(rel, str) or not rel.strip():
        raise PathSafetyError(f"empty path in manifest: {rel!r}")
    if "\x00" in rel:
        raise PathSafetyError(f"NUL byte in path: {rel!r}")
    candidate = rel.replace("\\", "/")
    if candidate.startswith("/") or re.match(r"^[A-Za-z]:", candidate):
        raise PathSafetyError(f"absolute path is not allowed: {rel!r}")
    parts = [part for part in candidate.split("/") if part not in ("", ".")]
    if not parts:
        raise PathSafetyError(f"path resolves to nothing: {rel!r}")
    if any(part == ".." for part in parts):
        raise PathSafetyError(f"parent traversal is not allowed: {rel!r}")
    return "/".join(parts)


def contained_path(root: str, rel: str) -> str:
    """Join ``rel`` onto ``root`` and prove the result stays inside ``root``.

    Also refuses symlinks: the MTP export must be plain files, and a symlink in
    the test tree would let a copy escape /mnt/SDCARD.
    """
    safe = safe_relpath(rel)
    root_real = os.path.realpath(root)
    target = os.path.realpath(os.path.join(root_real, safe))
    if target != root_real and not target.startswith(root_real + os.sep):
        raise PathSafetyError(f"path escapes {root_real}: {rel!r}")
    probe = root_real
    for part in safe.split("/"):
        probe = os.path.join(probe, part)
        if os.path.islink(probe):
            raise PathSafetyError(f"symlink is not allowed in the MTP test tree: {rel!r}")
        if not os.path.exists(probe):
            break
    return target


@dataclass
class Entry:
    relpath: str
    size: int
    sha256: str

    def as_dict(self) -> dict:
        return asdict(self)


def build_entries(root: str, relpaths) -> list:
    entries = []
    for rel in relpaths:
        path = contained_path(root, rel)
        entries.append(Entry(safe_relpath(rel), os.path.getsize(path), sha256_file(path)))
    return entries


def write_manifest(directory: str, run_id: str, origin: str, entries) -> str:
    payload = {
        "tool": TOOL_NAME,
        "tool_version": TOOL_VERSION,
        "dataset_version": DATASET_VERSION,
        "run_id": run_id,
        "origin": origin,
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": [entry.as_dict() for entry in entries],
    }
    path = os.path.join(directory, MANIFEST_NAME)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    return path


def read_manifest(directory: str) -> dict:
    path = os.path.join(directory, MANIFEST_NAME)
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload.get("tool") != TOOL_NAME:
        raise PathSafetyError(f"manifest was not written by {TOOL_NAME}: {path}")
    if not RUN_ID_RE.match(str(payload.get("run_id", ""))):
        raise PathSafetyError(f"manifest has an invalid run id: {path}")
    files = payload.get("files")
    if not isinstance(files, list) or not files:
        raise PathSafetyError(f"manifest lists no files: {path}")
    for item in files:
        safe_relpath(item.get("relpath", ""))
        int(item.get("size", -1))
        if not re.match(r"^[0-9a-f]{64}$", str(item.get("sha256", ""))):
            raise PathSafetyError(f"manifest has an invalid digest: {path}")
    return payload


def write_marker(directory: str, run_id: str, dataset_profile: str) -> str:
    payload = {
        "tool": TOOL_NAME,
        "tool_version": TOOL_VERSION,
        "dataset_version": DATASET_VERSION,
        "run_id": run_id,
        "dataset_profile": dataset_profile,
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "note": "Created by the BaseOS MTP integrity test tool; safe to delete with mtp-cleanup.sh",
    }
    path = os.path.join(directory, MARKER_NAME)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    return path


def read_marker(directory: str) -> dict:
    path = os.path.join(directory, MARKER_NAME)
    if not os.path.isfile(path):
        raise PathSafetyError(
            f"refusing to touch {directory}: {MARKER_NAME} is missing, so this "
            "directory was not created by the MTP integrity test tool"
        )
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload.get("tool") != TOOL_NAME:
        raise PathSafetyError(
            f"refusing to touch {directory}: marker belongs to {payload.get('tool')!r}"
        )
    return payload


def open_tool_dir(storage_root: str, run_id: str, must_exist: bool = True) -> str:
    """Resolve ``<storage_root>/baseos-mtp-test-<run_id>`` and vet it."""
    name = test_dir_name(run_id)
    root_real = os.path.realpath(storage_root)
    path = os.path.realpath(os.path.join(root_real, name))
    if os.path.dirname(path) != root_real:
        raise PathSafetyError(f"test directory must be a direct child of {root_real}")
    if os.path.islink(os.path.join(root_real, name)):
        raise PathSafetyError(f"test directory is a symlink: {path}")
    if must_exist and not os.path.isdir(path):
        raise PathSafetyError(f"test directory does not exist: {path}")
    return path


def marker_matches(marker: dict, run_id: str) -> bool:
    return marker.get("tool") == TOOL_NAME and marker.get("run_id") == run_id
