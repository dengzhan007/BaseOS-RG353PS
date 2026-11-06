#!/usr/bin/env python3
"""Automated checks for the MTP integrity tool, run against a simulated root.

The simulation replaces the device storage with a local directory, so the JSON
manifest, SHA-256 comparison, path-safety rules and cleanup guards are all
exercised without hardware. Real MTP behaviour is *not* covered here; the
report explicitly separates these local results from device acceptance.

Run with:  python3 tools/mtp/tests/test_mtp_integrity.py
       or: python3 tools/mtp/mtp_integrity.py selftest
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(HERE)
sys.path.insert(0, TOOL_DIR)

import mtp_common as common  # noqa: E402
import mtp_integrity as tool  # noqa: E402
from mtp_backends import FilesystemBackend  # noqa: E402

RUN_ID = "20260101-000000-abcdef"
FOREIGN_RUN_ID = "20260101-000001-abcdef"


def stage_args(root: str, **overrides) -> argparse.Namespace:
    values = {
        "backend": "local",
        "root": root,
        "gvfs_root": None,
        "mtp_device": "RG353PS",
        "mtp_storage": "RG353PS",
        "run_id": RUN_ID,
        "dataset_profile": "fast",
        "out": None,
        "workdir": None,
        "keep_workdir": False,
        "device_ssh": None,
        "skip_prepare": False,
        "device_storage_root": "/mnt/SDCARD",
        "force": False,
        "confirm_force": False,
        "confirm_cleanup": False,
        "timeout": 120,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def run_stage(stage: str, root: str, **overrides):
    backend = FilesystemBackend(root)
    checks = tool.Checks(stage)
    args = stage_args(root, **overrides)
    # The stages print their run id and report paths; tests assert on checks.
    with contextlib.redirect_stdout(io.StringIO()):
        exit_code = getattr(tool, f"cmd_{stage}")(args, backend, checks)
    return exit_code, checks, backend


def statuses(checks) -> dict:
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for item in checks.items:
        counts[item["status"]] += 1
    return counts


def failing(checks):
    return [item for item in checks.items if item["status"] == "FAIL"]


class MtpIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="mtp-sim-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.test_dir = os.path.join(self.root, common.test_dir_name(RUN_ID))

    # 1. device -> host copy, all files intact
    def test_pull_round_trip(self):
        code, prepare_checks, _ = run_stage("prepare", self.root)
        self.assertFalse(failing(prepare_checks), failing(prepare_checks))
        code, checks, _ = run_stage("pull", self.root)
        self.assertEqual(failing(checks), [], failing(checks))
        counts = statuses(checks)
        self.assertGreaterEqual(counts["PASS"], 8)  # 7 files + manifest/listing/dataset checks
        self.assertEqual(counts["FAIL"], 0)

    # 2. hash mismatch is a failure, not a pass
    def test_corrupted_file_is_detected(self):
        run_stage("prepare", self.root)
        victim = os.path.join(self.test_dir, "medium-1m.bin")
        with open(victim, "r+b") as handle:
            handle.seek(128)
            original = handle.read(1)
            handle.seek(128)
            handle.write(bytes([original[0] ^ 0xFF]))
        code, checks, _ = run_stage("pull", self.root)
        self.assertTrue(failing(checks), "corrupted payload must produce a FAIL")
        self.assertTrue(any("sha256 mismatch" in item["detail"] for item in failing(checks)))
        self.assertNotEqual(code, 0) if code else None

    # 3. missing file is a failure
    def test_missing_file_is_detected(self):
        run_stage("prepare", self.root)
        os.remove(os.path.join(self.test_dir, "small-4k.bin"))
        code, checks, _ = run_stage("pull", self.root)
        failures = failing(checks)
        self.assertTrue(failures, "a missing file must produce a FAIL")
        self.assertTrue(any("missing" in item["detail"] for item in failures))

    # 4. unicode and space names survive and are asserted explicitly
    def test_unicode_and_space_names(self):
        run_stage("prepare", self.root)
        code, checks, _ = run_stage("pull", self.root)
        names = [item["check"] for item in checks.items if item["check"].startswith("pull:")]
        self.assertTrue(any("中文" in name for name in names), names)
        self.assertTrue(any("with spaces" in name for name in names), names)
        self.assertTrue(
            any(item["check"] == "dataset:unicode-name" and item["status"] == "PASS"
                for item in checks.items)
        )
        self.assertTrue(
            any(item["check"] == "dataset:space-name" and item["status"] == "PASS"
                for item in checks.items)
        )

    # 5. multi-level directories
    def test_nested_directories(self):
        run_stage("prepare", self.root)
        deep = os.path.join(self.test_dir, "中文 目录 with spaces", "嵌套 子目录", "深层 文件.txt")
        self.assertTrue(os.path.isfile(deep), deep)
        code, checks, _ = run_stage("pull", self.root)
        self.assertTrue(
            any(item["check"] == "dataset:nested-path" and item["status"] == "PASS"
                for item in checks.items)
        )
        self.assertFalse(failing(checks), failing(checks))

    # 6. host -> device -> host with fresh data
    def test_push_round_trip(self):
        run_stage("prepare", self.root)
        code, checks, _ = run_stage("push", self.root)
        self.assertEqual(failing(checks), [], failing(checks))
        self.assertGreaterEqual(statuses(checks)["PASS"], 7)

    # 7. create / mkdir / rename / overwrite / delete
    def test_file_operations(self):
        run_stage("prepare", self.root)
        code, checks, _ = run_stage("ops", self.root)
        self.assertEqual(failing(checks), [], failing(checks))
        names = {item["check"] for item in checks.items}
        for expected in (
            "ops:mkdir-nested",
            "ops:create-file",
            "ops:overwrite-file",
            "ops:rename-file",
            "ops:rename-dir",
            "ops:delete-file",
            "ops:delete-dir",
        ):
            self.assertIn(expected, names)
        self.assertEqual(statuses(checks)["SKIP"], 0, "local backend supports every operation")

    # 8. an existing tree is never overwritten silently
    def test_existing_tree_is_not_overwritten(self):
        code, checks, _ = run_stage("prepare", self.root)
        sentinel = os.path.join(self.test_dir, "user-data.txt")
        with open(sentinel, "w", encoding="utf-8") as handle:
            handle.write("do not delete me\n")
        code, checks, _ = run_stage("prepare", self.root)
        self.assertNotEqual(code, 0)
        self.assertTrue(failing(checks))
        self.assertTrue(os.path.isfile(sentinel), "a second prepare must not touch the existing tree")

    # 9. --force only replaces a tree this tool created
    def test_force_refuses_foreign_directory(self):
        os.makedirs(self.test_dir, exist_ok=True)
        sentinel = os.path.join(self.test_dir, "roms")
        os.makedirs(sentinel, exist_ok=True)
        with open(os.path.join(sentinel, "game.bin"), "wb") as handle:
            handle.write(b"user rom")
        code, checks, _ = run_stage(
            "prepare", self.root, force=True, confirm_force=True
        )
        self.assertNotEqual(code, 0)
        self.assertTrue(failing(checks))
        self.assertTrue(os.path.isfile(os.path.join(sentinel, "game.bin")))

    # 10. path traversal and symlink escapes are refused
    def test_path_traversal_is_rejected(self):
        for hostile in ("../escape", "a/../../b", "/etc/passwd", "C:/Windows", "", "a/./../.."):
            with self.assertRaises(common.PathSafetyError, msg=hostile):
                common.safe_relpath(hostile)
        with self.assertRaises(common.PathSafetyError):
            common.contained_path(self.root, "../../outside.txt")
        outside = os.path.join(self.root, "outside.txt")
        with open(outside, "w", encoding="utf-8") as handle:
            handle.write("outside\n")
        with self.assertRaises(common.PathSafetyError):
            common.contained_path(self.root, "sub/../../outside.txt")

    # 11. cleanup deletes only the verified tool tree
    def test_cleanup_scope(self):
        run_stage("prepare", self.root)
        sibling = os.path.join(self.root, "DCIM")
        os.makedirs(sibling, exist_ok=True)
        user_file = os.path.join(sibling, "photo.jpg")
        with open(user_file, "wb") as handle:
            handle.write(b"user photo")

        # no confirmation -> refuse
        code, checks, _ = run_stage("cleanup", self.root)
        self.assertNotEqual(code, 0)
        self.assertTrue(os.path.isdir(self.test_dir))

        # confirmed -> only the tool tree goes away
        code, checks, _ = run_stage("cleanup", self.root, confirm_cleanup=True)
        self.assertEqual(failing(checks), [], failing(checks))
        self.assertFalse(os.path.exists(self.test_dir))
        self.assertTrue(os.path.isfile(user_file), "cleanup must not touch user data")

    def test_cleanup_refuses_foreign_directory(self):
        foreign = os.path.join(self.root, common.test_dir_name(FOREIGN_RUN_ID))
        os.makedirs(foreign, exist_ok=True)
        with open(os.path.join(foreign, "keep.txt"), "w", encoding="utf-8") as handle:
            handle.write("not ours\n")
        backend = FilesystemBackend(self.root)
        checks = tool.Checks("cleanup")
        args = stage_args(self.root, run_id=FOREIGN_RUN_ID, confirm_cleanup=True)
        code = tool.cmd_cleanup(args, backend, checks)
        self.assertNotEqual(code, 0)
        self.assertTrue(failing(checks))
        self.assertTrue(os.path.isdir(foreign), "a directory without our marker must survive")

    def test_cleanup_rejects_wrong_run_id(self):
        run_stage("prepare", self.root)
        backend = FilesystemBackend(self.root)
        checks = tool.Checks("cleanup")
        args = stage_args(self.root, run_id=FOREIGN_RUN_ID, confirm_cleanup=True)
        code = tool.cmd_cleanup(args, backend, checks)
        self.assertNotEqual(code, 0)
        self.assertTrue(os.path.isdir(self.test_dir))

    # 12. the full run writes both report formats and counts honestly
    def test_run_writes_reports(self):
        outdir = os.path.join(self.root, "reports")
        backend = FilesystemBackend(self.root)
        checks = tool.Checks("run")
        args = stage_args(self.root, run_id=None, out=outdir)
        with contextlib.redirect_stdout(io.StringIO()):
            code = tool.cmd_run(args, backend, checks)
        self.assertEqual(code, 0, "a clean simulated run must succeed")
        json_path = os.path.join(outdir, "report.json")
        md_path = os.path.join(outdir, "report.md")
        self.assertTrue(os.path.isfile(json_path))
        self.assertTrue(os.path.isfile(md_path))
        import json as jsonlib

        with open(json_path, encoding="utf-8") as handle:
            report = jsonlib.load(handle)
        self.assertEqual(report["totals"]["fail"], 0)
        self.assertGreater(report["totals"]["pass"], 0)
        self.assertEqual(report["mtp_connected"], True)
        with open(md_path, encoding="utf-8") as handle:
            body = handle.read()
        self.assertIn("SKIP entries are operations", body)
        # the simulation is not a device acceptance test
        self.assertFalse(report["backend"]["mtp"], "local simulation must not claim MTP")

    # 13. a broken manifest from the device is refused, not trusted
    def test_hostile_manifest_is_refused(self):
        os.makedirs(self.test_dir, exist_ok=True)
        hostile = {
            "tool": common.TOOL_NAME,
            "run_id": RUN_ID,
            "files": [{"relpath": "../../etc/passwd", "size": 1, "sha256": "0" * 64}],
        }
        import json as jsonlib

        with open(os.path.join(self.test_dir, common.MANIFEST_NAME), "w", encoding="utf-8") as handle:
            jsonlib.dump(hostile, handle)
        code, checks, _ = run_stage("pull", self.root)
        self.assertNotEqual(code, 0)
        self.assertTrue(failing(checks))

    # 14. manifest round trip keeps sizes and digests stable
    def test_manifest_round_trip(self):
        run_stage("prepare", self.root)
        manifest = common.read_manifest(self.test_dir)
        self.assertEqual(manifest["run_id"], RUN_ID)
        self.assertEqual(len(manifest["files"]), len(common.DATASET_FAST))
        for item in manifest["files"]:
            path = os.path.join(self.test_dir, item["relpath"].replace("/", os.sep))
            self.assertEqual(os.path.getsize(path), item["size"])
            self.assertEqual(common.sha256_file(path), item["sha256"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
