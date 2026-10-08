#!/usr/bin/env python3
"""
Ensure a usable Python 3.11 for the ZK agent (pyzkfp).

If the current interpreter is not 3.10–3.12, download the official Windows
embeddable 3.11.9 into tools\\.py311\\ and return its python.exe path.

Usage:
  python zk_ensure_python.py
  -> prints absolute path to python.exe on stdout (last line)
  -> exit 0 on success
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
PY311_DIR = os.path.join(TOOLS, ".py311")
PY311_EXE = os.path.join(PY311_DIR, "python.exe")
EMBED_URL = (
    "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip"
)
GET_PIP_URL = "https://bootstrap.pypa.io/get-pip.py"


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _ok_version(major: int, minor: int) -> bool:
    return (3, 10) <= (major, minor) <= (3, 12)


def _find_system_ok() -> str | None:
    # Prefer py launcher
    for ver in ("3.11", "3.12", "3.10"):
        try:
            r = subprocess.run(
                ["py", f"-{ver}", "-c", "import sys; print(sys.executable)"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            path = (r.stdout or "").strip()
            if r.returncode == 0 and path and os.path.isfile(path):
                return path
        except Exception:
            pass
    # Current interpreter
    if _ok_version(*sys.version_info[:2]) and os.path.isfile(sys.executable):
        return sys.executable
    return None


def _patch_pth(py_dir: str) -> None:
    # Enable site-packages for embeddable distro.
    for name in os.listdir(py_dir):
        if name.endswith("._pth"):
            path = os.path.join(py_dir, name)
            text = open(path, encoding="utf-8").read()
            lines = []
            for line in text.splitlines():
                if line.strip().startswith("#import site"):
                    lines.append("import site")
                elif line.strip() == "import site":
                    lines.append("import site")
                else:
                    lines.append(line)
            if "import site" not in "\n".join(lines):
                lines.append("import site")
            open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
            return


def _ensure_embed() -> str:
    if os.path.isfile(PY311_EXE):
        _log(f"[OK] Using bundled Python 3.11: {PY311_EXE}")
        return PY311_EXE

    _log("[..] Downloading Python 3.11.9 embeddable (~10 MB)…")
    os.makedirs(PY311_DIR, exist_ok=True)
    zip_path = os.path.join(PY311_DIR, "python311-embed.zip")
    urllib.request.urlretrieve(EMBED_URL, zip_path)
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(PY311_DIR)
    try:
        os.remove(zip_path)
    except Exception:
        pass
    _patch_pth(PY311_DIR)

    get_pip = os.path.join(PY311_DIR, "get-pip.py")
    _log("[..] Installing pip into embeddable Python…")
    urllib.request.urlretrieve(GET_PIP_URL, get_pip)
    subprocess.check_call([PY311_EXE, get_pip, "--no-warn-script-location"])
    _log(f"[OK] Bundled Python ready: {PY311_EXE}")
    return PY311_EXE


def main() -> int:
    found = _find_system_ok()
    if found:
        _log(f"[OK] System Python OK: {found}")
        print(found)
        return 0
    try:
        path = _ensure_embed()
        print(path)
        return 0
    except Exception as e:
        _log(f"[X] Could not bootstrap Python 3.11: {e}")
        _log(
            "Install manually: "
            "https://www.python.org/downloads/release/python-3119/"
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
