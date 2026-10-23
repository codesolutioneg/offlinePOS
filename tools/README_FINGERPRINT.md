# Fingerprint on a new Windows PC

## Two things must be true

1. **Python 3.10 / 3.11 / 3.12** (not 3.13 or 3.14 — `pyzkfp` has no wheels there)
2. **ZK9500 USB driver** installed (Device Manager must not show Error / Code 28)

## Fix Python (this is why `pip install pyzkfp` failed on 3.14)

1. Download [Python 3.11.9](https://www.python.org/downloads/release/python-3119/) → Windows installer (64-bit)
2. Tick **Add python.exe to PATH**
3. Open a new Command Prompt in `tools\` and run:

```bat
py -3.11 -m pip install flask flask-cors pythonnet pyzkfp
start_zk_agent.bat
```

## Fix ZK9500 USB driver

Device Manager → Universal Serial Bus devices → **ZK9500** (Error):

1. Install **ZKFinger SDK for Windows** from ZKTeco (includes the USB driver),  
   or put `zkusbdevices.inf` (+ `.sys` / `.cat`) under `tools\zk_driver\` and re-run `start_zk_agent.bat` **as Administrator**.
2. Hardware ID should be `USB\VID_1B55&PID_0124`.

## Tracking

- `%LOCALAPPDATA%\OfflinePOS\zk_agent.log`
- `%LOCALAPPDATA%\OfflinePOS\zk_setup_status.json`
- In the app: **Settings → Fingerprint setup**
