#!/usr/bin/env python3
"""
ZK fingerprint bootstrap for Offline POS (any Windows till).

Runs before the Flask agent. Auto-installs missing Python packages, copies SDK
DLLs onto PATH, optionally installs a USB driver from tools/zk_driver, and
writes a status file the Flutter till can show for tracking.

Status:  %LOCALAPPDATA%\\OfflinePOS\\zk_setup_status.json
Log:     %LOCALAPPDATA%\\OfflinePOS\\zk_agent.log
Also:    tools/zk_setup_status.json (next to this script)
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List

TOOLS = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.join(TOOLS, "zk_sdk")
DRIVER = os.path.join(TOOLS, "zk_driver")
LOCAL = os.path.join(os.environ.get("LOCALAPPDATA", TOOLS), "OfflinePOS")
STATUS_LOCAL = os.path.join(LOCAL, "zk_setup_status.json")
STATUS_TOOLS = os.path.join(TOOLS, "zk_setup_status.json")
LOG_PATH = os.path.join(LOCAL, "zk_agent.log")

DLLS = [
    "libzkfp.dll",
    "libzkfpcsharp.dll",
    "zkfinger10.dll",
    "ZKFPCap.dll",
    "libusb0.dll",
    "libusb0_x64.dll",
    "libiomp5md.dll",
    "libcorrect.dll",
    "libsilkid.dll",
    "fpslib.dll",
    "fppswsk12.dll",
    "zkfpslibLow.dll",
]

PACKAGES = ["flask", "flask-cors", "pythonnet", "pyzkfp"]


def _log(msg: str) -> None:
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        os.makedirs(LOCAL, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _write_status(payload: Dict[str, Any]) -> None:
    payload = {
        **payload,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "log_path": LOG_PATH,
        "tools_dir": TOOLS,
    }
    raw = json.dumps(payload, indent=2, ensure_ascii=False)
    for path in (STATUS_LOCAL, STATUS_TOOLS):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(raw)
        except Exception as e:
            _log(f"[warn] could not write {path}: {e}")


def _step(checks: List[Dict[str, Any]], code: str, ok: bool, detail: str) -> None:
    checks.append({"code": code, "ok": ok, "detail": detail})
    mark = "OK" if ok else "FAIL"
    _log(f"[{mark}] {code}: {detail}")


def ensure_dlls(checks: List[Dict[str, Any]]) -> bool:
    src_dir = SDK if os.path.isfile(os.path.join(SDK, "libzkfp.dll")) else TOOLS
    if not os.path.isfile(os.path.join(src_dir, "libzkfp.dll")):
        _step(
            checks,
            "sdk_dlls",
            False,
            f"Missing libzkfp.dll — expected under {SDK} or {TOOLS}",
        )
        return False

    copied = 0
    for name in DLLS:
        src = os.path.join(src_dir, name)
        dst = os.path.join(TOOLS, name)
        if not os.path.isfile(src):
            continue
        try:
            if (
                not os.path.isfile(dst)
                or os.path.getsize(src) != os.path.getsize(dst)
            ):
                shutil.copy2(src, dst)
                copied += 1
        except Exception as e:
            _step(checks, "sdk_dlls", False, f"Copy {name} failed: {e}")
            return False

    sensors_src = os.path.join(src_dir, "ZKFPSensors")
    sensors_dst = os.path.join(TOOLS, "ZKFPSensors")
    if os.path.isdir(sensors_src) and not os.path.isdir(sensors_dst):
        try:
            shutil.copytree(sensors_src, sensors_dst)
        except Exception as e:
            _log(f"[warn] ZKFPSensors copy: {e}")

    os.environ["PATH"] = (
        SDK + os.pathsep + TOOLS + os.pathsep + os.environ.get("PATH", "")
    )
    _step(
        checks,
        "sdk_dlls",
        True,
        f"libzkfp.dll ready (from {src_dir}, copied {copied} files)",
    )
    return True


def ensure_packages(checks: List[Dict[str, Any]]) -> bool:
    major, minor = sys.version_info[:2]
    if (major, minor) < (3, 10) or (major, minor) >= (3, 13):
        _step(
            checks,
            "python_packages",
            False,
            f"pyzkfp needs Python 3.10–3.12 (this is {major}.{minor}). "
            "Install Python 3.11 from python.org (Add to PATH), then re-run "
            "tools\\start_zk_agent.bat",
        )
        return False

    missing: List[str] = []
    for pkg in PACKAGES:
        mod = "flask_cors" if pkg == "flask-cors" else pkg.replace("-", "_")
        try:
            __import__(mod)
        except Exception:
            missing.append(pkg)

    if not missing:
        _step(checks, "python_packages", True, "flask / pythonnet / pyzkfp present")
        return True

    _log(f"[..] pip install missing: {', '.join(missing)}")
    req = os.path.join(TOOLS, "requirements-zk.txt")
    cmd = [sys.executable, "-m", "pip", "install", "--upgrade"]
    if os.path.isfile(req):
        cmd += ["-r", req]
    else:
        cmd += PACKAGES
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,
            cwd=TOOLS,
        )
        pip_out = ((r.stderr or "") + "\n" + (r.stdout or "")).strip()
        if r.returncode != 0:
            err = pip_out[-800:]
            _step(
                checks,
                "python_packages",
                False,
                f"pip failed (exit {r.returncode}): {err}",
            )
            return False
    except Exception as e:
        _step(checks, "python_packages", False, f"pip error: {e}")
        return False

    still = []
    for pkg in PACKAGES:
        mod = "flask_cors" if pkg == "flask-cors" else pkg.replace("-", "_")
        try:
            __import__(mod)
        except Exception:
            still.append(pkg)
    if still:
        hint = ""
        if "pyzkfp" in still or "pythonnet" in still:
            hint = (
                " Tip: use Python 3.11 — 3.13/3.14 have no pyzkfp wheels. "
                "https://www.python.org/downloads/release/python-3119/"
            )
        _step(
            checks,
            "python_packages",
            False,
            f"Still missing after pip: {', '.join(still)}. "
            f"Run: {sys.executable} -m pip install {' '.join(PACKAGES)}.{hint}",
        )
        return False
    _step(checks, "python_packages", True, "Packages installed")
    return True


def ensure_driver(checks: List[Dict[str, Any]]) -> None:
    """Best-effort USB driver install when tools/zk_driver/*.inf exists."""
    flag = os.path.join(LOCAL, "zk_driver_ok.flag")
    problem = _usb_problem_hint()
    usb_ok = not bool(problem)

    if not os.path.isdir(DRIVER):
        if problem:
            _step(
                checks,
                "usb_driver",
                False,
                problem
                + " Missing tools\\zk_driver — use a station zip that includes "
                "zk_driver, or run install_zk_driver.bat from a full build.",
            )
        else:
            _step(
                checks,
                "usb_driver",
                True,
                "No bundled zk_driver; no obvious USB problem detected",
            )
        return

    infs = []
    for root, _, files in os.walk(DRIVER):
        for f in files:
            if f.lower().endswith(".inf"):
                infs.append(os.path.join(root, f))
    if not infs:
        _step(checks, "usb_driver", False, f"zk_driver folder empty of .inf: {DRIVER}")
        return

    # Already healthy — nothing to do.
    if usb_ok and os.path.isfile(flag):
        _step(checks, "usb_driver", True, "USB OK (driver previously installed)")
        return
    if usb_ok:
        try:
            os.makedirs(LOCAL, exist_ok=True)
            with open(flag, "w", encoding="utf-8") as f:
                f.write("ok\n")
        except Exception:
            pass
        _step(checks, "usb_driver", True, "USB reader Status=OK")
        return

    # Device present but Error — try pnputil (needs Admin for real install).
    ok_any = False
    errors: List[str] = []
    for inf in infs:
        try:
            r = subprocess.run(
                ["pnputil", "/add-driver", inf, "/install"],
                capture_output=True,
                text=True,
                timeout=120,
            )
            out = ((r.stdout or "") + (r.stderr or "")).strip()
            if r.returncode == 0:
                ok_any = True
            else:
                errors.append(f"{os.path.basename(inf)}: {out[:220] or f'exit {r.returncode}'}")
        except Exception as e:
            errors.append(str(e))

    try:
        subprocess.run(
            ["pnputil", "/scan-devices"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception:
        pass

    problem_after = _usb_problem_hint()
    if not problem_after:
        try:
            os.makedirs(LOCAL, exist_ok=True)
            with open(flag, "w", encoding="utf-8") as f:
                f.write("ok\n")
        except Exception:
            pass
        _step(checks, "usb_driver", True, f"Installed INF via pnputil ({len(infs)} file(s))")
        return

    install_bat = os.path.join(TOOLS, "install_zk_driver.bat")
    hint = (
        f"{problem_after}. "
        f"Right-click Run as Administrator: {install_bat}"
        if os.path.isfile(install_bat)
        else problem_after
    )
    if ok_any:
        _step(
            checks,
            "usb_driver",
            False,
            hint + " (pnputil reported success but device still Error — unplug/replug)",
        )
    else:
        _step(
            checks,
            "usb_driver",
            False,
            hint
            + (
                " | pnputil: " + ("; ".join(errors)[:280] if errors else "needs Administrator")
            ),
        )


def _usb_problem_hint() -> str:
    """Return a short hint if a ZK-like device has no driver (Code 28)."""
    ps = r"""
$ErrorActionPreference='SilentlyContinue'
$devs = Get-PnpDevice -PresentOnly | Where-Object {
  $_.FriendlyName -match 'ZK|Finger|Biometric|1b55' -or
  $_.InstanceId -match 'VID_1B55|VID_6993'
}
foreach ($d in $devs) {
  if ($d.Status -ne 'OK') {
    Write-Output ("DEVICE:" + $d.FriendlyName + "|STATUS:" + $d.Status + "|ID:" + $d.InstanceId)
  }
}
"""
    try:
        r = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                ps,
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        out = (r.stdout or "").strip()
        if out:
            first = out.splitlines()[0]
            return f"USB reader problem — {first}"
    except Exception:
        pass
    return ""


def probe_sdk(checks: List[Dict[str, Any]]) -> None:
    """Try Init/GetDeviceCount without keeping the device open."""
    try:
        try:
            import pythonnet

            pythonnet.load("netfx")
        except Exception:
            pass
        from pyzkfp import ZKFP2

        z = ZKFP2()
        z.Init()
        try:
            n = z.GetDeviceCount()
            _step(
                checks,
                "device_probe",
                n > 0,
                f"GetDeviceCount={n}"
                + ("" if n > 0 else " — plug in the reader / install USB driver"),
            )
        finally:
            try:
                z.Terminate()
            except Exception:
                pass
    except Exception as e:
        _step(
            checks,
            "device_probe",
            False,
            f"SDK init failed: {e}",
        )


def main() -> int:
    _log("==== ZK setup check start ====")
    _log(f"python={sys.executable} version={sys.version.split()[0]}")
    checks: List[Dict[str, Any]] = []

    major, minor = sys.version_info[:2]
    py_ok = (3, 10) <= (major, minor) <= (3, 12)
    _step(
        checks,
        "python",
        py_ok,
        f"{sys.version.split()[0]} ({sys.executable})"
        if py_ok
        else f"{major}.{minor} is not supported — install Python 3.11 "
        "(https://www.python.org/downloads/release/python-3119/) and Add to PATH",
    )

    dll_ok = ensure_dlls(checks) if py_ok else False
    pkg_ok = ensure_packages(checks) if py_ok else False
    ensure_driver(checks)
    if py_ok and dll_ok and pkg_ok:
        probe_sdk(checks)

    failed = [c for c in checks if not c["ok"]]
    ok = len(failed) == 0
    # Soft-fail: usb_driver / device_probe alone should not block agent start
    # when packages+DLLs are fine — agent can still run and report connect errors.
    hard = [
        c
        for c in failed
        if c["code"] in ("python", "sdk_dlls", "python_packages")
    ]
    summary = (
        "ready"
        if ok
        else (
            "blocked: " + "; ".join(f"{c['code']}={c['detail']}" for c in hard)
            if hard
            else "degraded: " + "; ".join(f"{c['code']}={c['detail']}" for c in failed)
        )
    )
    _write_status(
        {
            "ok": ok,
            "can_start_agent": len(hard) == 0,
            "summary": summary,
            "checks": checks,
            "python": sys.executable,
        }
    )
    _log(f"==== ZK setup done: {summary} ====")
    return 0 if len(hard) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
