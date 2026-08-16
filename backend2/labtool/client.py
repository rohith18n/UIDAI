"""
HTTP client for the single-finger backend (app.py, port 5002).

Every call returns a Call: the parsed payload, the HTTP status and the wall-clock
time the round trip took. Non-2xx responses are *not* an exception — /enroll,
/authenticate and /process all use 422 with a meaningful body to report a quality
failure or a spoof, and the bench needs to show those to the user rather than
swallow them.
"""

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

import requests

DEFAULT_BASE_URL = "http://35.255.138.39:5002"
TIMEOUT_SECONDS = 120

CONFIG_PATH = Path(__file__).resolve().parent / "labtool_config.json"


# ══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ══════════════════════════════════════════════════════════════════════════════

def load_base_url() -> str:
    try:
        return json.loads(CONFIG_PATH.read_text()).get("base_url") or DEFAULT_BASE_URL
    except Exception:
        return DEFAULT_BASE_URL


def save_base_url(url: str) -> None:
    try:
        CONFIG_PATH.write_text(json.dumps({"base_url": url.strip().rstrip("/")}, indent=2))
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════════════════════
# CALL RESULT
# ══════════════════════════════════════════════════════════════════════════════

@dataclass
class Call:
    endpoint: str
    payload: dict = field(default_factory=dict)
    status: int = 0
    wall_ms: float = 0.0
    transport_error: str = ""

    @property
    def ok(self) -> bool:
        """HTTP 2xx and no transport failure. Says nothing about `success` in the body."""
        return not self.transport_error and 200 <= self.status < 300

    @property
    def succeeded(self) -> bool:
        """The backend's own verdict — 2xx *and* success:true."""
        return self.ok and bool(self.payload.get("success", True))

    @property
    def error(self) -> str:
        if self.transport_error:
            return self.transport_error
        return (self.payload.get("error")
                or self.payload.get("message")
                or (f"HTTP {self.status}" if not self.ok else ""))


def _request(method: str, base_url: str, endpoint: str, **kwargs) -> Call:
    url = f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"
    kwargs.setdefault("timeout", TIMEOUT_SECONDS)
    t0 = time.perf_counter()
    try:
        response = requests.request(method, url, **kwargs)
    except requests.RequestException as exc:
        return Call(endpoint=endpoint, wall_ms=(time.perf_counter() - t0) * 1000.0,
                    transport_error=f"{type(exc).__name__}: {exc}")
    wall_ms = (time.perf_counter() - t0) * 1000.0

    try:
        payload = response.json()
        if not isinstance(payload, dict):
            payload = {"data": payload}
    except ValueError:
        payload = {"error": f"Non-JSON response: {response.text[:400]}"}

    return Call(endpoint=endpoint, payload=payload, status=response.status_code, wall_ms=wall_ms)


def _files(image_bytes: bytes, filename: str = "capture.jpg") -> dict:
    return {"image": (filename, image_bytes, "application/octet-stream")}


# ══════════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ══════════════════════════════════════════════════════════════════════════════

def health(base_url: str) -> Call:
    return _request("GET", base_url, "/health", timeout=15)


def quality_check(base_url: str, image_bytes: bytes, filename: str = "capture.jpg") -> Call:
    """FP-03 fast path — YOLO at imgsz=320, pixel-only blur/brightness/glare, plus ROI centring."""
    return _request("POST", base_url, "/quality_check", files=_files(image_bytes, filename))


def process(base_url: str, image_bytes: bytes, filename: str = "capture.jpg") -> Call:
    """The full chain — crop, liveness, segmentation, enhancement, minutiae. Returns images + minutiae."""
    return _request("POST", base_url, "/process", files=_files(image_bytes, filename))


def export_fir(base_url: str, image_bytes: bytes, finger_position: int = 0,
               source_dpi=None, filename: str = "capture.jpg") -> Call:
    """FP-06 — 500 DPI normalisation then an ISO/IEC 19794-4 finger image record."""
    data = {"finger_position": str(int(finger_position))}
    if source_dpi:
        data["source_dpi"] = str(int(source_dpi))
    return _request("POST", base_url, "/export_fir", files=_files(image_bytes, filename), data=data)


def enroll(base_url: str, image_bytes: bytes, name: str, uid: str, batch: str,
           finger_position: int = 0, filename: str = "capture.jpg") -> Call:
    """Optional — writes into the *server's* uidai.db so the Flutter app sees the same gallery."""
    data = {"name": name, "uid": uid, "batch": batch,
            "finger_position": str(int(finger_position))}
    return _request("POST", base_url, "/enroll", files=_files(image_bytes, filename), data=data)


def endpoint_present(base_url: str, endpoint: str) -> bool:
    """
    Is this route deployed at all?

    Posting nothing gets a 400 "image required" from a route that exists and a 404 from
    one that does not, which distinguishes a stale deployment from a broken request
    without uploading anything. /export_fir in particular shipped with the FIR encoder
    commit and is absent from older servers.
    """
    call = _request("POST", base_url, endpoint, timeout=15)
    return call.status != 404 and not call.transport_error


def authenticate(base_url: str, image_bytes: bytes, batch: str,
                 filename: str = "capture.jpg") -> Call:
    """Server-side 1:N. Returns only the top match — the bench ranks locally instead."""
    return _request("POST", base_url, "/authenticate",
                    files=_files(image_bytes, filename), data={"batch": batch})
