"""
ZK Fingerprint Agent — Offline POS (local only)
────────────────────────────────────────────────
Flask on 127.0.0.1:9201 for ZKTeco USB readers (ZK9500 / ZK8500R / …).

No cloud, no Firebase, no remote auto-update. Templates live on disk and the
Flutter till syncs them over the shop LAN.

Requirements (auto-installed by start_zk_agent.bat when missing):
    pip install flask flask-cors pythonnet pyzkfp

Native DLLs: tools/zk_sdk/ next to this script (bundled with the till).
"""

import json
import logging
import os
import sys
import threading
import time
from typing import Dict, List, Optional

ZK_VERSION = "1.1.1-offline"

# Put bundled SDK on PATH *before* pyzkfp loads libzkfp.dll
_AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_DIR = os.path.join(_AGENT_DIR, "zk_sdk")


def _bootstrap_native_sdk() -> None:
    """Ensure libzkfp.dll (+ deps) are findable on any PC that ships tools/."""
    import shutil

    try:
        os.chdir(_AGENT_DIR)
    except Exception:
        pass

    search_dirs = []
    if os.path.isdir(_SDK_DIR):
        search_dirs.append(_SDK_DIR)
    search_dirs.append(_AGENT_DIR)

    dll_names = [
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
    # Prefer zk_sdk copies next to the agent (pythonnet LoadLibrary looks at CWD).
    if os.path.isdir(_SDK_DIR):
        for name in dll_names:
            src = os.path.join(_SDK_DIR, name)
            dst = os.path.join(_AGENT_DIR, name)
            if os.path.isfile(src) and (
                not os.path.isfile(dst)
                or os.path.getsize(src) != os.path.getsize(dst)
            ):
                try:
                    shutil.copy2(src, dst)
                except Exception:
                    pass
        sensors_src = os.path.join(_SDK_DIR, "ZKFPSensors")
        sensors_dst = os.path.join(_AGENT_DIR, "ZKFPSensors")
        if os.path.isdir(sensors_src) and not os.path.isdir(sensors_dst):
            try:
                shutil.copytree(sensors_src, sensors_dst)
            except Exception:
                pass

    path_parts = [d for d in search_dirs if os.path.isdir(d)]
    os.environ["PATH"] = os.pathsep.join(path_parts + [os.environ.get("PATH", "")])

    # Force-load the native DLL so .NET sees it before ZKFPM_Init.
    try:
        import ctypes

        for d in path_parts:
            candidate = os.path.join(d, "libzkfp.dll")
            if os.path.isfile(candidate):
                ctypes.WinDLL(candidate)
                break
    except Exception:
        pass


_bootstrap_native_sdk()

from flask import Flask, jsonify, request
from flask_cors import CORS

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────
# pyzkfp import (Windows only)
# pythonnet 3.x requires explicit runtime load before 'import clr'
# ─────────────────────────────────────────────────────────────
try:
    import pythonnet
    pythonnet.load("netfx")
except Exception:
    pass  # not on Windows or already loaded

try:
    from pyzkfp import ZKFP2
    ZKFPAvailable = True
    logger.info("pyzkfp loaded successfully.")
except (ImportError, Exception) as e:
    ZKFPAvailable = False
    logger.warning(
        f"pyzkfp not available ({e}). Running in simulation mode. "
        "Install with: pip install pyzkfp pythonnet"
    )

# ─────────────────────────────────────────────────────────────
# Global state
# ─────────────────────────────────────────────────────────────
zkfp2: Optional[object] = None          # ZKFP2 instance
_connected: bool = False
_latest_template: Optional[List[int]] = None
_template_lock = threading.Lock()
_device_lock = threading.Lock()         # guards AcquireFingerprint vs CloseDevice
_connect_lock = threading.Lock()        # serialises connect / ensure
_polling_thread: Optional[threading.Thread] = None
_stop_polling = threading.Event()
_poll_generation = 0  # bumped on every disconnect so stale threads exit

# templates: {user_id: [template1_list, template2_list, ...]}
templates: Dict[str, List[List[int]]] = {}

TEMPLATES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates.json")

# ─────────────────────────────────────────────────────────────
# Persistence helpers
# ─────────────────────────────────────────────────────────────
def _load_templates_from_disk() -> None:
    """Load templates from templates.json on startup."""
    global templates
    if os.path.exists(TEMPLATES_FILE):
        try:
            with open(TEMPLATES_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            templates = {str(k): [list(t) for t in v] for k, v in data.items()}
            logger.info(
                f"Loaded templates from disk: {len(templates)} users."
            )
        except Exception as e:
            logger.error(f"Failed to load templates.json: {e}")
    else:
        logger.info("No templates.json found — starting with empty templates.")


def _save_templates_to_disk() -> bool:
    """Write current templates dict to templates.json."""
    try:
        with open(TEMPLATES_FILE, "w", encoding="utf-8") as f:
            json.dump(templates, f)
        logger.info(f"Templates saved to disk ({len(templates)} users).")
        return True
    except Exception as e:
        logger.error(f"Failed to save templates.json: {e}")
        return False


# ─────────────────────────────────────────────────────────────
# Background polling thread
# ─────────────────────────────────────────────────────────────


def _bytes_summary(data: list, n: int = 16) -> str:
    """Returns first N bytes as hex + zero-check for diagnostics."""
    snippet = data[:n]
    hex_str = ' '.join(f'{b:02X}' for b in snippet)
    all_zeros = all(b == 0 for b in data)
    non_zero = sum(1 for b in data if b != 0)
    return f"[{hex_str}...] size={len(data)} all_zeros={all_zeros} non_zero_bytes={non_zero}"


def _do_disconnect() -> None:
    """Clean up device resources and reset global state. Safe to call multiple times.
    IMPORTANT: sets _connected=False FIRST so the polling loop stops calling
    AcquireFingerprint, then waits for any in-flight call to finish via
    _device_lock before calling CloseDevice/Terminate.
    """
    global zkfp2, _connected, _polling_thread, _stop_polling, _poll_generation
    _connected = False
    _poll_generation += 1  # invalidate any in-flight poll loops
    _stop_polling.set()
    if _polling_thread is not None and _polling_thread.is_alive():
        _polling_thread.join(timeout=3.0)
    _polling_thread = None
    # Keep _stop_polling set until a new connect clears it — avoids a zombie
    # thread that survived join() from racing the next OpenDevice.
    with _device_lock:
        try:
            if zkfp2 is not None:
                zkfp2.CloseDevice()
                zkfp2.Terminate()
        except Exception:
            pass
        zkfp2 = None


def _polling_loop(generation: int) -> None:
    """Background thread: continuously polls AcquireFingerprint()."""
    global _latest_template, _connected
    logger.info("═" * 60)
    logger.info(f"[POLL] Polling thread started (gen={generation}).")
    logger.info("═" * 60)
    consecutive_errors = 0
    DISCONNECT_THRESHOLD = 12  # ~0.6s of real errors before giving up
    while not _stop_polling.is_set() and generation == _poll_generation:
        try:
            if zkfp2 is not None and _connected:
                with _device_lock:
                    if (
                        not _connected
                        or zkfp2 is None
                        or generation != _poll_generation
                    ):
                        break
                    result = zkfp2.AcquireFingerprint()
                consecutive_errors = 0
                if result is not None:
                    template, _img = result
                    raw = bytes(template)
                    raw_list = list(raw)
                    with _template_lock:
                        _latest_template = raw_list
                    logger.info(f"[POLL] ✅ Finger detected — {_bytes_summary(raw_list)}")
                    if all(b == 0 for b in raw_list):
                        logger.warning(
                            "[POLL] ⚠️  ALL BYTES ARE ZERO — placement may be wrong"
                        )
        except Exception as e:
            if generation != _poll_generation:
                break
            consecutive_errors += 1
            logger.warning(
                f"[POLL] ❌ Device error #{consecutive_errors}/{DISCONNECT_THRESHOLD}: {e}"
            )
            if consecutive_errors >= DISCONNECT_THRESHOLD:
                logger.warning(
                    "[POLL] ⚠️  Device likely unplugged — resetting connection state."
                )
                _connected = False
                break
        _stop_polling.wait(timeout=0.05)
    logger.info(f"[POLL] Polling thread stopped (gen={generation}).")


def _ensure_device() -> tuple[bool, str]:
    """Connect if needed. Returns (ok, message)."""
    global zkfp2, _connected, _polling_thread, _stop_polling, _poll_generation
    with _connect_lock:
        if _connected and zkfp2 is not None:
            if _polling_thread is not None and _polling_thread.is_alive():
                return True, "already connected"
            logger.warning("[ENSURE] connected flag set but poll dead — reconnecting")

        if not ZKFPAvailable:
            return False, "pyzkfp not available on this platform."

        _do_disconnect()

        try:
            zkfp2 = ZKFP2()
            zkfp2.Init()
            count = zkfp2.GetDeviceCount()
            if count == 0:
                try:
                    zkfp2.Terminate()
                except Exception:
                    pass
                zkfp2 = None
                return False, "No fingerprint device found."

            zkfp2.OpenDevice(0)
            _poll_generation += 1
            gen = _poll_generation
            _stop_polling.clear()
            _connected = True  # before thread so first poll iteration is live
            _polling_thread = threading.Thread(
                target=_polling_loop,
                args=(gen,),
                daemon=True,
                name=f"zk-poll-{gen}",
            )
            _polling_thread.start()
            logger.info(f"Device opened. Device count: {count} (gen={gen})")
            return True, f"Connected. Devices found: {count}"
        except Exception as e:
            logger.error(f"_ensure_device error: {e}")
            _connected = False
            return False, str(e)


# ─────────────────────────────────────────────────────────────
# Flask app
# ─────────────────────────────────────────────────────────────
app = Flask(__name__)
CORS(app, resources={r"/*": {"origins": "*"}})

# Suppress Werkzeug per-request access log (keeps our custom logs clean)
logging.getLogger("werkzeug").setLevel(logging.WARNING)


# ── /ping ────────────────────────────────────────────────────
@app.route("/ping", methods=["GET"])
def ping():
    logger.info("GET /ping")
    return jsonify({"status": "ok"})


def _read_setup_status() -> dict:
    """Load last bootstrap result (written by zk_setup_check.py)."""
    candidates = [
        os.path.join(
            os.environ.get("LOCALAPPDATA", ""),
            "OfflinePOS",
            "zk_setup_status.json",
        ),
        os.path.join(_AGENT_DIR, "zk_setup_status.json"),
    ]
    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                data["status_file"] = path
                return data
        except Exception:
            continue
    return {}


# ── /diag ────────────────────────────────────────────────────
@app.route("/diag", methods=["GET"])
def diag():
    """Structured health for Flutter tracking on a new / secondary PC."""
    setup = _read_setup_status()
    with _template_lock:
        has_fp = _latest_template is not None
    poll_alive = (
        _polling_thread is not None and _polling_thread.is_alive()
    )
    device_ok = bool(_connected and zkfp2 is not None and poll_alive)
    issues = []
    if not ZKFPAvailable:
        issues.append("pyzkfp not loaded — run tools\\start_zk_agent.bat")
    if not device_ok:
        issues.append(
            "Reader not connected — check USB cable / ZKFinger driver "
            "(see setup checks)"
        )
    for c in setup.get("checks") or []:
        if isinstance(c, dict) and not c.get("ok"):
            issues.append(f"{c.get('code')}: {c.get('detail')}")

    log_path = setup.get("log_path") or os.path.join(
        os.environ.get("LOCALAPPDATA", ""), "OfflinePOS", "zk_agent.log"
    )
    return jsonify({
        "success": True,
        "agent": "ok",
        "version": ZK_VERSION,
        "pyzkfp": ZKFPAvailable,
        "connected": _connected,
        "poll_alive": poll_alive,
        "device_ok": device_ok,
        "has_fingerprint": has_fp,
        "users_count": len(templates),
        "setup": setup,
        "issues": issues,
        "log_path": log_path,
        "ok": device_ok and ZKFPAvailable,
        "summary": (
            "Fingerprint reader ready"
            if device_ok and ZKFPAvailable
            else ("; ".join(issues) if issues else "Not ready")
        ),
    })


# ── /connect ─────────────────────────────────────────────────
@app.route("/connect", methods=["POST"])
def connect():
    logger.info("POST /connect")
    ok, message = _ensure_device()
    if ok:
        logger.info("═" * 60)
        return jsonify({"success": True, "message": message})
    # Persist last connect failure for Flutter when agent is up but USB fails.
    try:
        setup = _read_setup_status()
        setup["last_connect_error"] = message
        setup["last_connect_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        path = os.path.join(
            os.environ.get("LOCALAPPDATA", _AGENT_DIR),
            "OfflinePOS",
            "zk_setup_status.json",
        )
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(setup, f, indent=2)
    except Exception:
        pass
    return jsonify({"success": False, "message": message})


# ── /disconnect ───────────────────────────────────────────────
@app.route("/disconnect", methods=["POST"])
def disconnect():
    logger.info("POST /disconnect")
    try:
        _do_disconnect()
        logger.info("Device disconnected.")
        return jsonify({"success": True, "message": "Disconnected."})
    except Exception as e:
        logger.error(f"/disconnect error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /status ──────────────────────────────────────────────────
@app.route("/status", methods=["GET"])
def status():
    logger.debug("GET /status")
    try:
        with _template_lock:
            has_fp = _latest_template is not None
        return jsonify({
            "connected": _connected,
            "has_fingerprint": has_fp,
            "users_count": len(templates),
        })
    except Exception as e:
        logger.error(f"/status error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /capture ─────────────────────────────────────────────────
@app.route("/capture", methods=["POST"])
def capture():
    """
    Waits for a fingerprint placement using the background poll buffer.
    Auto-reconnects if the reader dropped.
    """
    logger.info("─" * 60)
    logger.info("[CAPTURE] POST /capture — waiting for fingerprint")
    try:
        ok, msg = _ensure_device()
        if not ok:
            logger.error(f"[CAPTURE] ❌ {msg}")
            return jsonify({"success": False, "message": msg})

        timeout_s = 15.0
        try:
            body = request.get_json(silent=True) or {}
            timeout_s = float(body.get("timeout", timeout_s))
        except Exception:
            pass
        timeout_s = max(5.0, min(timeout_s, 45.0))

        with _template_lock:
            global _latest_template
            _latest_template = None
        logger.info(f"[CAPTURE] Cleared stale template. Waiting up to {timeout_s:.0f}s...")

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if not _connected:
                ok, msg = _ensure_device()
                if not ok:
                    return jsonify({"success": False, "message": msg})
            time.sleep(0.08)
            with _template_lock:
                tmpl = _latest_template
            if tmpl is not None:
                all_zeros = all(b == 0 for b in tmpl)
                logger.info(f"[CAPTURE] ✅ Got template — {_bytes_summary(tmpl)}")
                if all_zeros:
                    logger.error("[CAPTURE] ❌ TEMPLATE IS ALL ZEROS — invalid capture!")
                    with _template_lock:
                        _latest_template = None
                    continue
                with _template_lock:
                    _latest_template = None
                return jsonify({"success": True, "template": tmpl})

        logger.warning("[CAPTURE] ⏱️  Timed out — no finger detected.")
        return jsonify({
            "success": False,
            "reason": "timeout",
            "message": "Timeout — no finger detected.",
        })

    except Exception as e:
        logger.error(f"[CAPTURE] ❌ Exception: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /register ────────────────────────────────────────────────
@app.route("/register", methods=["POST"])
def register():
    """
    body: {"user_id": "str", "template": [int, ...]}
    Appends the template to templates[user_id] (does not replace).
    """
    logger.info("─" * 60)
    logger.info("[REGISTER] POST /register")
    try:
        body = request.get_json(force=True)
        user_id: str = str(body.get("user_id", "")).strip()
        template_list: List[int] = body.get("template", [])

        if not user_id:
            logger.error("[REGISTER] ❌ user_id missing")
            return jsonify({"success": False, "message": "user_id is required."})
        if not template_list:
            logger.error("[REGISTER] ❌ template is empty")
            return jsonify({"success": False, "message": "template is empty."})

        all_zeros = all(b == 0 for b in template_list)
        logger.info(f"[REGISTER] Template for '{user_id}': {_bytes_summary(template_list)}")
        if all_zeros:
            logger.error(f"[REGISTER] ❌ TEMPLATE IS ALL ZEROS for user '{user_id}' — rejecting!")
            return jsonify({"success": False, "message": "Template is all zeros — invalid."})

        if user_id in templates:
            templates[user_id].append(list(template_list))
        else:
            templates[user_id] = [list(template_list)]

        logger.info(
            f"[REGISTER] ✅ Registered for '{user_id}' — "
            f"total templates in memory: {len(templates[user_id])}."
        )
        return jsonify({"success": True})

    except Exception as e:
        logger.error(f"[REGISTER] ❌ Exception: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /identify ────────────────────────────────────────────────
@app.route("/identify", methods=["POST"])
def identify():
    """
    Wait for a finger (like /capture), then match against in-memory templates.
    Returns user_id on match. reason=timeout|no_match|… when unsuccessful.
    """
    logger.info("─" * 60)
    logger.info("[IDENTIFY] POST /identify — waiting for fingerprint")
    try:
        ok, msg = _ensure_device()
        if not ok:
            logger.error(f"[IDENTIFY] ❌ {msg}")
            return jsonify({
                "success": False,
                "reason": "not_connected",
                "message": msg,
            })

        # Drop stale buffer so we only match a NEW placement.
        with _template_lock:
            global _latest_template
            _latest_template = None

        timeout_s = 12.0
        try:
            body = request.get_json(silent=True) or {}
            timeout_s = float(body.get("timeout", timeout_s))
        except Exception:
            pass
        timeout_s = max(3.0, min(timeout_s, 30.0))

        deadline = time.time() + timeout_s
        probe = None
        while time.time() < deadline:
            time.sleep(0.08)
            with _template_lock:
                probe = _latest_template
            if probe is not None:
                break

        if probe is None:
            logger.info("[IDENTIFY] ⏱️  No finger within timeout.")
            return jsonify({
                "success": False,
                "reason": "timeout",
                "message": "Timeout — no finger detected.",
            })

        logger.info(f"[IDENTIFY] Probe template: {_bytes_summary(probe)}")
        if all(b == 0 for b in probe):
            logger.error("[IDENTIFY] ❌ Probe is ALL ZEROS — invalid fingerprint!")
            return jsonify({
                "success": False,
                "reason": "invalid",
                "message": "Probe template is all zeros.",
            })

        logger.info(f"[IDENTIFY] Searching among {len(templates)} registered users...")
        probe_bytes = bytes(probe)

        best_user_id: Optional[str] = None
        best_score: int = 0

        for user_id, tmpl_list in templates.items():
            user_best = 0
            for i, tmpl in enumerate(tmpl_list):
                all_z = all(b == 0 for b in tmpl)
                if all_z:
                    logger.warning(
                        f"[IDENTIFY]   ⚠️  Template #{i} for user '{user_id}' "
                        "is ALL ZEROS — skipping!"
                    )
                    continue
                try:
                    tmpl_bytes = bytes(tmpl)
                    score = zkfp2.DBMatch(probe_bytes, tmpl_bytes)
                    logger.info(
                        f"[IDENTIFY]   User '{user_id}' tmpl#{i}: "
                        f"score={score} (size={len(tmpl)})"
                    )
                    if score > user_best:
                        user_best = score
                except Exception as match_err:
                    logger.warning(
                        f"[IDENTIFY]   DBMatch error for '{user_id}' "
                        f"tmpl#{i}: {match_err}"
                    )

            if user_best > best_score:
                best_score = user_best
                best_user_id = user_id

        MATCH_THRESHOLD = 20
        logger.info(
            f"[IDENTIFY] Best match: user='{best_user_id}' "
            f"score={best_score} threshold={MATCH_THRESHOLD}"
        )
        if best_user_id and best_score >= MATCH_THRESHOLD:
            logger.info(f"[IDENTIFY] ✅ MATCH — user='{best_user_id}' score={best_score}")
            # Consume probe so the next listen needs a fresh finger.
            with _template_lock:
                _latest_template = None
            return jsonify({
                "success": True,
                "user_id": best_user_id,
                "score": best_score,
            })

        logger.warning(
            f"[IDENTIFY] ❌ NO MATCH — best score={best_score} "
            f"< threshold={MATCH_THRESHOLD} (bank={len(templates)} users)"
        )
        with _template_lock:
            _latest_template = None
        return jsonify({
            "success": False,
            "reason": "no_match" if templates else "empty_bank",
            "user_id": None,
            "score": best_score,
        })

    except Exception as e:
        logger.error(f"[IDENTIFY] ❌ Exception: {e}")
        return jsonify({"success": False, "reason": "error", "message": str(e)})

# ── /merge ─────────────────────────────────────────────────────
@app.route("/merge", methods=["POST"])
def merge():
    """
    Merges 3 raw capture templates into a single registration template.
    body: {"templates": [[int,...], [int,...], [int,...]]}
    Returns: {"success": true, "template": [int,...]}
    """
    logger.info("─" * 60)
    logger.info("[MERGE] POST /merge")
    try:
        if not ZKFPAvailable or zkfp2 is None:
            logger.error("[MERGE] ❌ Device not connected!")
            return jsonify({"success": False, "message": "Device not connected."})

        body = request.get_json(force=True)
        raw_list = body.get("templates", [])
        if len(raw_list) < 3:
            logger.error(f"[MERGE] ❌ Only {len(raw_list)} templates provided, need 3.")
            return jsonify({"success": False, "message": "Need exactly 3 templates."})

        for i, t in enumerate(raw_list[:3]):
            t_list = list(t)
            logger.info(f"[MERGE]   Input tmpl#{i}: {_bytes_summary(t_list)}")
            if all(b == 0 for b in t_list):
                logger.error(f"[MERGE] ❌ Input tmpl#{i} is ALL ZEROS — capture was invalid!")
                return jsonify({"success": False, "message": f"Template #{i} is all zeros — capture failed."})

        from System import Array, Byte  # noqa
        def to_clr(lst):
            arr = Array[Byte](len(lst))
            for i, v in enumerate(lst):
                arr[i] = v
            return arr

        t1 = to_clr(raw_list[0])
        t2 = to_clr(raw_list[1])
        t3 = to_clr(raw_list[2])

        reg_temp, reg_len = zkfp2.DBMerge(t1, t2, t3)
        merged = list(bytes(reg_temp))[:reg_len]
        logger.info(f"[MERGE] DBMerge output: {_bytes_summary(merged)}")
        if all(b == 0 for b in merged):
            logger.error("[MERGE] ❌ DBMerge output is ALL ZEROS — merge failed silently!")
            return jsonify({"success": False, "message": "DBMerge returned all zeros."})
        logger.info(f"[MERGE] ✅ Merge succeeded — {reg_len} bytes.")
        return jsonify({"success": True, "template": merged})

    except Exception as e:
        logger.error(f"[MERGE] ❌ Exception: {e}")
        return jsonify({"success": False, "message": str(e)})

# ── /clear_pending ───────────────────────────────────────────
@app.route("/clear_pending", methods=["POST"])
def clear_pending():
    """Clears the latest pending fingerprint template."""
    logger.info("POST /clear_pending")
    try:
        global _latest_template
        with _template_lock:
            _latest_template = None
        logger.info("Pending template cleared.")
        return jsonify({"success": True})
    except Exception as e:
        logger.error(f"/clear_pending error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /load_templates ──────────────────────────────────────────
@app.route("/load_templates", methods=["POST"])
def load_templates():
    """
    body: {"templates": [{"user_id": "str", "templates": [[int,...], ...]}, ...]}
    Replaces the in-memory templates entirely.
    """
    logger.info("POST /load_templates")
    try:
        body = request.get_json(force=True)
        incoming = body.get("templates", [])

        logger.info(f"[LOAD_TMPL] Received {len(incoming)} user entries.")
        new_templates: Dict[str, List[List[int]]] = {}
        for entry in incoming:
            uid = str(entry.get("user_id", "")).strip()
            tmpl_lists = entry.get("templates", [])
            if uid and tmpl_lists:
                new_templates[uid] = [list(t) for t in tmpl_lists]
                for i, t in enumerate(tmpl_lists):
                    t_list = list(t)
                    all_z = all(b == 0 for b in t_list)
                    logger.info(f"[LOAD_TMPL]   User '{uid}' tmpl#{i}: {_bytes_summary(t_list)}")
                    if all_z:
                        logger.error(
                            f"[LOAD_TMPL]   ❌ User '{uid}' tmpl#{i} IS ALL ZEROS — "
                            "template was saved incorrectly (check local enrol / LAN sync)."
                        )

        templates.clear()
        templates.update(new_templates)

        logger.info(f"[LOAD_TMPL] ✅ Loaded {len(templates)} users into memory.")
        return jsonify({"success": True, "users_loaded": len(templates)})

    except Exception as e:
        logger.error(f"/load_templates error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── DELETE /template/<user_id> ───────────────────────────────
@app.route("/template/<user_id>", methods=["DELETE"])
def delete_template(user_id: str):
    logger.info(f"DELETE /template/{user_id}")
    try:
        if user_id in templates:
            del templates[user_id]
            logger.info(f"Deleted templates for user '{user_id}'.")
            return jsonify({"success": True})
        return jsonify({"success": False, "message": f"User '{user_id}' not found."})
    except Exception as e:
        logger.error(f"DELETE /template error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── GET /templates ───────────────────────────────────────────
@app.route("/templates", methods=["GET"])
def get_templates():
    """Returns only user_ids (not the raw template bytes) for inspection."""
    logger.info("GET /templates")
    try:
        info = [
            {"user_id": uid, "template_count": len(tmpl_list)}
            for uid, tmpl_list in templates.items()
        ]
        return jsonify({"success": True, "users": info})
    except Exception as e:
        logger.error(f"GET /templates error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ── /save_templates ──────────────────────────────────────────
@app.route("/save_templates", methods=["POST"])
def save_templates():
    logger.info("POST /save_templates")
    try:
        ok = _save_templates_to_disk()
        return jsonify({"success": ok})
    except Exception as e:
        logger.error(f"/save_templates error: {e}")
        return jsonify({"success": False, "message": str(e)})


# ─────────────────────────────────────────────────────────────
# Entry point (local only — no remote update / Firebase)
# ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    _load_templates_from_disk()
    logger.info(
        f"Starting Offline POS ZK Fingerprint Agent v{ZK_VERSION} "
        f"on http://127.0.0.1:9201 (local LAN templates only)"
    )
    app.run(host="127.0.0.1", port=9201, debug=False, threaded=True)


