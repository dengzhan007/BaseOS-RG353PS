#!/usr/bin/env python3
"""Host adapters that move files through MTP (or a stand-in for it).

Every adapter exposes the same small surface so the integrity checks in
``mtp_integrity.py`` never care which one is in use:

    list_dir(rel_dir) -> [{"name", "relpath", "is_dir", "size"}]
    get_file(rel_path, local_path)
    put_file(local_path, rel_dir)
    make_dir(rel_dir)
    rename(rel_from, rel_to)
    delete(rel_path, recursive)

Adapters must never silently downgrade a failure into success. When an adapter
cannot express an operation at all it reports ``capabilities[key] = False`` and
the caller records SKIP, not PASS.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

from mtp_common import PathSafetyError, contained_path, safe_relpath


class BackendError(RuntimeError):
    pass


class Backend:
    name = "abstract"
    capabilities = {
        "list": False,
        "get": False,
        "put": False,
        "mkdir": False,
        "rename": False,
        "delete": False,
        "overwrite": False,
        "readback_after_put": False,
    }
    #: True when the adapter moves bytes over MTP rather than the local FS.
    is_mtp = False

    def describe(self) -> dict:
        return {"backend": self.name, "capabilities": dict(self.capabilities), "mtp": self.is_mtp}

    def list_dir(self, rel_dir: str):
        raise BackendError("list is not supported by this backend")

    def get_file(self, rel_path: str, local_path: str):
        raise BackendError("download is not supported by this backend")

    def put_file(self, local_path: str, rel_dir: str):
        raise BackendError("upload is not supported by this backend")

    def make_dir(self, rel_dir: str):
        raise BackendError("mkdir is not supported by this backend")

    def rename(self, rel_from: str, rel_to: str):
        raise BackendError("rename is not supported by this backend")

    def delete(self, rel_path: str, recursive: bool = False):
        raise BackendError("delete is not supported by this backend")


class FilesystemBackend(Backend):
    """A storage root reachable as a plain directory.

    Used for the simulated MTP root in automated tests and for a gvfs/libmtp
    FUSE mount on Linux, where the kernel exposes the MTP storage as POSIX
    paths. Containment checks run on every operation.
    """

    capabilities = {
        "list": True,
        "get": True,
        "put": True,
        "mkdir": True,
        "rename": True,
        "delete": True,
        "overwrite": True,
        "readback_after_put": True,
    }

    def __init__(self, root: str, name: str = "local", is_mtp: bool = False):
        self.root = os.path.realpath(root)
        if not os.path.isdir(self.root):
            raise BackendError(f"storage root does not exist: {self.root}")
        self.name = name
        self.is_mtp = is_mtp

    def describe(self) -> dict:
        info = super().describe()
        info["root"] = self.root
        return info

    def _path(self, rel: str) -> str:
        return contained_path(self.root, rel)

    def list_dir(self, rel_dir: str):
        directory = self._path(rel_dir) if rel_dir not in ("", ".", "/") else self.root
        if not os.path.isdir(directory):
            raise BackendError(f"not a directory on the device: {rel_dir}")
        items = []
        for name in sorted(os.listdir(directory)):
            full = os.path.join(directory, name)
            if os.path.islink(full):
                continue
            rel = os.path.join(rel_dir, name).replace("\\", "/") if rel_dir not in ("", ".") else name
            rel = rel.lstrip("/")
            if os.path.isdir(full):
                items.append({"name": name, "relpath": rel, "is_dir": True, "size": 0})
            else:
                items.append(
                    {"name": name, "relpath": rel, "is_dir": False, "size": os.path.getsize(full)}
                )
        return items

    def get_file(self, rel_path: str, local_path: str):
        source = self._path(rel_path)
        if not os.path.isfile(source):
            raise BackendError(f"file is missing on the device: {rel_path}")
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        shutil.copyfile(source, local_path)

    def put_file(self, local_path: str, rel_dir: str):
        directory = self._path(rel_dir) if rel_dir not in ("", ".") else self.root
        os.makedirs(directory, exist_ok=True)
        target = contained_path(self.root, os.path.join(rel_dir, os.path.basename(local_path)).lstrip("/"))
        shutil.copyfile(local_path, target)

    def make_dir(self, rel_dir: str):
        os.makedirs(self._path(rel_dir), exist_ok=True)

    def rename(self, rel_from: str, rel_to: str):
        source = self._path(rel_from)
        target = self._path(rel_to)
        if not os.path.exists(source):
            raise BackendError(f"rename source is missing: {rel_from}")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.replace(source, target)

    def delete(self, rel_path: str, recursive: bool = False):
        target = self._path(rel_path)
        if not os.path.exists(target):
            raise BackendError(f"delete target is missing: {rel_path}")
        if os.path.isdir(target):
            if not recursive:
                os.rmdir(target)
            else:
                shutil.rmtree(target)
        else:
            os.remove(target)


class LinuxMtpToolsBackend(Backend):
    """Disabled adapter: ``mtp-tools`` takes object IDs, not remote paths.

    ``mtp-files`` prints one record per object (File ID, Filename, File size,
    Parent ID, Storage ID) and ``mtp-getfile`` / ``mtp-sendfile`` /
    ``mtp-newfolder`` / ``mtp-delfile`` address objects by those numeric IDs.
    The previous implementation passed remote *paths* in the ID positions and
    guessed the storage id, so every call would have been wrong on a real
    libmtp build. Building a path -> ID map cannot be verified in this
    environment, so the adapter is disabled instead of shipped as guesswork.

    ``--backend linux-mtp-tools`` fails loudly; ``auto`` never selects it. Use
    the Windows WPD adapter or a gvfs MTP mount.
    """

    name = "linux-mtp-tools"
    is_mtp = True
    capabilities = {
        "list": False,
        "get": False,
        "put": False,
        "mkdir": False,
        "rename": False,
        "delete": False,
        "overwrite": False,
        "readback_after_put": False,
    }

    DISABLED_REASON = (
        "the linux-mtp-tools backend is disabled: libmtp's mtp-tools address "
        "objects by numeric file/folder/storage IDs, so a path-based adapter "
        "cannot be implemented reliably without re-verifying the ID mapping on "
        "a real libmtp build. Use --backend windows-wpd (Windows) or "
        "--backend linux-gvfs --gvfs-root <mounted path> (Linux), or "
        "--backend local --root <dir> for the simulation."
    )

    def __init__(self, storage_name: str = "RG353PS", timeout: int = 900):
        raise BackendError(self.DISABLED_REASON)


class WindowsWpdBackend(Backend):
    """Windows Portable Devices adapter driven through hosts/wpd.ps1.

    The PowerShell helper talks to the Shell namespace (the same WPD stack
    Explorer uses). Rename has no dependable scriptable verb, so it is declared
    unsupported rather than faked.
    """

    name = "windows-wpd"
    is_mtp = True
    # The Shell namespace raises modal confirmation dialogs for delete and for
    # replacing an existing name, and no CopyHere flag suppresses them. Those
    # verbs are therefore reported unsupported rather than hanging the run.
    capabilities = {
        "list": True,
        "get": True,
        "put": True,
        "mkdir": True,
        "rename": False,
        "delete": False,
        "overwrite": False,
        "readback_after_put": False,
    }

    def __init__(self, device: str = "RG353PS", storage: str = "SDCARD", timeout: int = 900):
        self.device = device
        self.storage = storage
        self.timeout = timeout
        self.script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hosts", "wpd.ps1")
        if not os.path.isfile(self.script):
            raise BackendError(f"missing PowerShell helper: {self.script}")
        if os.name != "nt" and shutil.which("powershell") is None:
            raise BackendError("windows-wpd backend requires Windows PowerShell")

    def _run(self, action: str, **kwargs):
        request = {
            "Action": action,
            "Device": self.device,
            "Storage": self.storage,
            "TimeoutSeconds": self.timeout,
        }
        request.update({key: value for key, value in kwargs.items() if value is not None})
        handle, request_path = tempfile.mkstemp(prefix="mtp-wpd-", suffix=".json")
        os.close(handle)
        with open(request_path, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(request, stream, ensure_ascii=False)
        argv = [
            "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", self.script, "-Request", request_path,
        ]
        try:
            result = subprocess.run(argv, capture_output=True, timeout=self.timeout + 60)
        except subprocess.TimeoutExpired:
            raise BackendError(f"wpd.ps1 {action} timed out after {self.timeout}s")
        finally:
            try:
                os.unlink(request_path)
            except OSError:
                pass
        text = result.stdout.decode("utf-8", "replace").strip()
        if not text:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise BackendError(f"wpd.ps1 {action} produced no output: {detail[:400]}")
        try:
            payload = json.loads(text.splitlines()[-1])
        except json.JSONDecodeError:
            raise BackendError(f"wpd.ps1 {action} returned non-JSON output: {text[:200]}")
        if not payload.get("ok"):
            raise BackendError(f"wpd.ps1 {action} reported: {payload.get('error', 'unknown error')}")
        return payload

    def list_dir(self, rel_dir: str):
        payload = self._run("list", Path=rel_dir.strip("/"))
        return payload.get("items", [])

    def get_file(self, rel_path: str, local_path: str):
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        self._run("get", Path=safe_relpath(rel_path), Local=os.path.abspath(local_path))

    def put_file(self, local_path: str, rel_dir: str):
        self._run("put", Path=rel_dir.strip("/"), Local=os.path.abspath(local_path))

    def make_dir(self, rel_dir: str):
        self._run("mkdir", Path=safe_relpath(rel_dir))

    def delete(self, rel_path: str, recursive: bool = False):
        # Never reach PowerShell: the helper refuses this verb and the tool must
        # not attempt a Shell delete that would pop a modal confirmation.
        raise BackendError(
            "windows-wpd cannot delete over MTP (modal Shell prompt). Remove the tree "
            "on the device with device/mtp-cleanup.sh --run-id <id> --confirm."
        )

    def rename(self, rel_from: str, rel_to: str):
        raise BackendError("windows-wpd has no scriptable rename verb for an MTP object")


def build_backend(args) -> Backend:
    """Pick an adapter from CLI flags, failing loudly instead of guessing."""
    choice = args.backend
    if choice == "auto":
        if os.name == "nt":
            choice = "windows-wpd"
        elif getattr(args, "gvfs_root", None):
            choice = "linux-gvfs"
        else:
            raise SystemExit(
                "no supported MTP host adapter detected; on Linux pass "
                "--backend linux-gvfs --gvfs-root <mounted MTP path>, on Windows "
                "use --backend windows-wpd, or pass --backend local --root DIR for "
                "the simulated run. The linux-mtp-tools adapter is disabled: "
                + LinuxMtpToolsBackend.DISABLED_REASON
            )

    if choice == "local":
        if not args.root:
            raise SystemExit("--backend local requires --root <simulated storage root>")
        return FilesystemBackend(args.root, name="local-simulation", is_mtp=False)

    if choice == "linux-gvfs":
        root = args.gvfs_root or args.root
        if not root:
            raise SystemExit("--backend linux-gvfs requires --gvfs-root <mounted path>")
        return FilesystemBackend(root, name="linux-gvfs", is_mtp=True)

    if choice == "linux-mtp-tools":
        raise SystemExit(LinuxMtpToolsBackend.DISABLED_REASON)

    if choice == "windows-wpd":
        return WindowsWpdBackend(device=args.mtp_device, storage=args.mtp_storage, timeout=args.timeout)

    raise SystemExit(f"unknown backend: {choice}")


def warn(message: str) -> None:
    sys.stderr.write(f"warning: {message}\n")
