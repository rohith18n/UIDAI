"""
FP-01 … FP-06 orchestration, written once and used by both the enrol tab and the
identify tab.

Up to three HTTP calls per image:
  /quality_check  → FP-01 detection + FP-03 quality (the fast in-memory path)
  /process        → FP-02 liveness, FP-05 preprocessing, and the minutiae set
  /export_fir     → FP-06 500 DPI normalisation + ISO/IEC 19794-4 record

/export_fir arrived with the FIR encoder commit, so a backend running older code answers
404. When that happens FP-06 falls back to encoding here with the same fir.py the backend
imports, from the preprocessed image /process already returned. Either way the record is
then put through `fir.decode_fir`, so conformance is demonstrated by round-tripping
rather than asserted.

Note this costs the server two or three YOLO+preprocess runs per image. Fine for a bench
and deliberately visible in the timing panel, but it means the wall-clock totals here are
not a per-capture latency figure.
"""

import base64
import io
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import fir  # noqa: E402
from labtool import client  # noqa: E402

# Which side of the spec's performance budget each stage belongs to.
# "device" = capture, QC, liveness, preprocessing, FIR creation — mandatory on-device, <5 s.
# "cloud"  = templatisation, matching and scoring — acceptable in the cloud for the PoC, <5 s.
BUDGET_DEVICE = "device"
BUDGET_CLOUD = "cloud"

FINGER_CHOICES = [
    ("Right index", 2), ("Left index", 7),
    ("Right thumb", 1), ("Right middle", 3), ("Right ring", 4), ("Right little", 5),
    ("Left thumb", 6), ("Left middle", 8), ("Left ring", 9), ("Left little", 10),
    ("Unknown", 0),
]
FINGER_NAMES = {code: label for label, code in FINGER_CHOICES}

MIN_MINUTIAE = 5  # same floor /enroll applies at app.py:1406


@dataclass
class Stage:
    ref: str
    title: str
    status: str = "pass"          # pass | warn | fail | skip
    summary: str = ""
    duration_ms: float = 0.0
    server_ms: float = None       # server-reported compute, when the endpoint gives it
    where: str = "cloud"          # where the work actually ran in this bench
    budget: str = BUDGET_DEVICE   # which spec budget it counts against
    data: dict = field(default_factory=dict)


@dataclass
class PipelineRun:
    ok: bool = False
    fail_ref: str = ""
    fail_reason: str = ""
    stages: list = field(default_factory=list)
    minutiae: list = field(default_factory=list)
    images: dict = field(default_factory=dict)   # name -> PIL.Image
    fir: dict = field(default_factory=dict)
    liveness: dict = field(default_factory=dict)
    quality: dict = field(default_factory=dict)
    det_conf: float = 0.0
    timings: dict = field(default_factory=dict)

    def stage(self, ref: str):
        for s in self.stages:
            if s.ref == ref:
                return s
        return None


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _b64_to_pil(data: str):
    if not data:
        return None
    try:
        return Image.open(io.BytesIO(base64.b64decode(data))).convert("RGB")
    except Exception:
        return None


def _np_to_pil(arr):
    if arr is None:
        return None
    try:
        return Image.fromarray(np.ascontiguousarray(arr)).convert("RGB")
    except Exception:
        return None


FIR_FIELD_MAP = [
    (0, 4, "Format identifier", "must be FIR\\0"),
    (4, 4, "Version", "010\\0"),
    (8, 4, "Record length", "uint32 BE, total bytes"),
    (12, 4, "CBEFF product ID", ""),
    (16, 2, "Capture device ID", ""),
    (18, 2, "Acquisition level", ""),
    (20, 1, "Number of fingers", ""),
    (21, 1, "Scale units", "1 = pixels per inch"),
    (22, 2, "Scan resolution X", ""),
    (24, 2, "Scan resolution Y", ""),
    (26, 2, "Image resolution X", "500 dpi target"),
    (28, 2, "Image resolution Y", "500 dpi target"),
    (30, 1, "Pixel depth", "bits"),
    (31, 1, "Compression", "0 = uncompressed"),
    (32, 4, "Finger block length", ""),
    (36, 1, "Finger position", "ISO code 0-10"),
    (37, 1, "Count of views", ""),
    (38, 1, "View number", ""),
    (39, 1, "Image quality", ""),
    (40, 1, "Impression type", "0 = live-scan plain"),
    (41, 2, "Image width", ""),
    (43, 2, "Image height", ""),
    (45, 1, "Reserved", ""),
]


def annotate_fir_header(record: bytes) -> list:
    """Break the 46 header bytes into labelled fields for the FP-06 card."""
    rows = []
    for offset, length, label, note in FIR_FIELD_MAP:
        chunk = record[offset:offset + length]
        if len(chunk) < length:
            break
        if label in ("Format identifier", "Version"):
            value = repr(bytes(chunk))
        elif length == 1:
            value = str(chunk[0])
        else:
            value = str(int.from_bytes(chunk, "big"))
        rows.append({
            "offset": f"{offset}..{offset + length - 1}",
            "field": label,
            "hex": chunk.hex(" ").upper(),
            "value": value,
            "note": note,
        })
    return rows


def _roundtrip(record: bytes) -> tuple:
    """Decode a record we just produced. Encoding without decoding is self-certification."""
    try:
        parsed = fir.decode_fir(record)
        return True, "", _np_to_pil(parsed["image"])
    except fir.FIRError as exc:
        return False, str(exc), None
    except Exception as exc:          # a decoder that crashes is also a failed round trip
        return False, f"{type(exc).__name__}: {exc}", None


def _fir_from_server(fir_call, finger_position: int) -> dict:
    payload = fir_call.payload
    record = base64.b64decode(payload.get("fir_base64", ""))
    ok, error, decoded = _roundtrip(record)
    return {
        "source": "server",
        "record": record,
        "record_bytes": payload.get("record_bytes", len(record)),
        "width": payload.get("width"),
        "height": payload.get("height"),
        "resolution_dpi": payload.get("resolution_dpi"),
        "finger_position": payload.get("finger_position", finger_position),
        "compression": payload.get("compression", "uncompressed"),
        "normalisation": payload.get("normalisation") or {},
        "pipeline_metrics": payload.get("pipeline_metrics") or {},
        "roundtrip_ok": ok,
        "roundtrip_error": error,
        "decoded_image": decoded,
        "encode_ms": 0.0,
        "header_fields": annotate_fir_header(record),
    }


def _fir_locally(preprocessed_b64: str, finger_position: int, source_dpi) -> dict:
    """
    Encode the record here, from the preprocessed image /process already returned.

    Same fir.py the backend imports, so the record is identical to what /export_fir would
    have produced — the difference is only where the CPU cycles were spent.
    """
    blank = {"source": "local", "record": None, "decoded_image": None,
             "normalisation": {}, "pipeline_metrics": {}, "encode_ms": 0.0,
             "roundtrip_ok": False, "roundtrip_error": "", "header_fields": []}

    if not preprocessed_b64:
        blank["error"] = "no preprocessed image to encode"
        return blank

    try:
        # PNG is lossless and the preprocessed image is single channel, so converting
        # back to L recovers the backend's exact pixel values.
        gray_pil = Image.open(io.BytesIO(base64.b64decode(preprocessed_b64))).convert("L")
        gray = np.array(gray_pil, dtype=np.uint8)
    except Exception as exc:
        blank["error"] = f"could not decode the preprocessed image: {exc}"
        return blank

    t0 = time.perf_counter()
    try:
        normalised, norm_info = fir.normalize_to_500dpi(gray, source_dpi=source_dpi)
        record = fir.encode_fir(normalised, finger_position=finger_position)
    except fir.FIRError as exc:
        blank["error"] = str(exc)
        blank["encode_ms"] = (time.perf_counter() - t0) * 1000.0
        return blank
    encode_ms = (time.perf_counter() - t0) * 1000.0

    ok, error, decoded = _roundtrip(record)
    height, width = normalised.shape[:2]
    return {
        "source": "local",
        "record": record,
        "record_bytes": len(record),
        "width": width,
        "height": height,
        "resolution_dpi": fir.TARGET_DPI,
        "finger_position": finger_position,
        "compression": "uncompressed",
        "normalisation": norm_info,
        "pipeline_metrics": {},
        "roundtrip_ok": ok,
        "roundtrip_error": error,
        "decoded_image": decoded,
        "encode_ms": encode_ms,
        "header_fields": annotate_fir_header(record),
    }


# ══════════════════════════════════════════════════════════════════════════════
# THE RUN
# ══════════════════════════════════════════════════════════════════════════════

def run_capture_pipeline(base_url: str, image_bytes: bytes, finger_position: int = 2,
                         filename: str = "capture.jpg", source_dpi=None) -> PipelineRun:
    """
    Walk one image through FP-01 … FP-06 and return every intermediate.

    A stage that fails does not always stop the run: a blurry frame or a spoof verdict is
    recorded and the walk continues, because seeing the remaining stages is the point of a
    bench. The two exceptions are no-finger-detected and a pipeline error, where there is
    genuinely nothing downstream to show.
    """
    run = PipelineRun()
    wall_total = 0.0

    # ── FP-01 Camera capture + detection ─────────────────────────────────────
    qc_call = client.quality_check(base_url, image_bytes, filename)
    wall_total += qc_call.wall_ms
    qc = qc_call.payload
    run.quality = qc

    original = _b64_to_pil(base64.b64encode(image_bytes).decode()) or None
    if original is None:
        try:
            original = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        except Exception:
            original = None
    if original is not None:
        run.images["original"] = original

    if qc_call.transport_error:
        run.stages.append(Stage(
            ref="FP-01", title="Camera Capture", status="fail",
            summary=f"Backend unreachable — {qc_call.transport_error}",
            duration_ms=qc_call.wall_ms, where="cloud", budget=BUDGET_DEVICE,
        ))
        run.fail_ref, run.fail_reason = "FP-01", qc_call.transport_error
        return run

    finger_detected = bool(qc.get("finger_detected"))
    det_conf = float(qc.get("detection_conf") or 0.0)
    run.det_conf = det_conf

    run.stages.append(Stage(
        ref="FP-01", title="Camera Capture",
        status="pass" if finger_detected else "fail",
        summary=(f"Finger detected, confidence {det_conf:.2f}" if finger_detected
                 else qc.get("guidance") or "No finger detected in frame"),
        duration_ms=qc_call.wall_ms,
        server_ms=qc.get("elapsed_ms"),
        where="cloud", budget=BUDGET_DEVICE,
        data={"detection_conf": det_conf,
              "in_roi": qc.get("in_roi"),
              "offset_x": qc.get("offset_x"), "offset_y": qc.get("offset_y"),
              "roi_guidance": qc.get("roi_guidance"),
              "raw": qc},
    ))

    if not finger_detected:
        run.fail_ref = "FP-01"
        run.fail_reason = qc.get("guidance") or "No finger detected"
        run.timings = {"wall_ms": wall_total}
        return run

    # ── FP-03 Quality control ────────────────────────────────────────────────
    issues = qc.get("issues") or []
    qc_passed = bool(qc.get("passed"))
    run.stages.append(Stage(
        ref="FP-03", title="Quality Control",
        status="pass" if qc_passed else "warn",
        summary=qc.get("guidance") or ("Quality acceptable" if qc_passed else "; ".join(issues)),
        duration_ms=0.0,                      # measured together with FP-01, one endpoint
        server_ms=qc.get("elapsed_ms"),
        where="cloud", budget=BUDGET_DEVICE,
        data={"blur": qc.get("blur") or {}, "brightness": qc.get("brightness") or {},
              "glare": qc.get("glare") or {}, "issues": issues,
              "in_roi": qc.get("in_roi"), "roi_guidance": qc.get("roi_guidance")},
    ))

    # ── /process — liveness, segmentation, enhancement, minutiae ─────────────
    proc_call = client.process(base_url, image_bytes, filename)
    wall_total += proc_call.wall_ms
    proc = proc_call.payload

    if not proc_call.succeeded:
        reason = proc_call.error or "pipeline failed"

        # /process gates on nothing — it fails when the image will not decode, when
        # detect_and_crop finds no finger, or when a model is missing. Liveness itself
        # never aborts it, so reporting this as a liveness failure would be wrong.
        detection_disagreement = "no finger detected" in reason.lower()

        run.stages.append(Stage(
            ref="FP-02", title="Basic Liveness", status="skip",
            summary="Did not run — the pipeline stopped before the liveness check.",
            where="cloud", budget=BUDGET_DEVICE,
        ))
        run.stages.append(Stage(
            ref="FP-05", title="Preprocessing Pipeline", status="fail",
            summary=(
                "The detector disagreed with the quality check: /quality_check found a "
                "finger at imgsz=320, /process re-ran detection at imgsz=800 and found "
                "none. That divergence is in app.py, not in this frame — a capture can "
                "pass the live preview and still be rejected at enrol."
                if detection_disagreement else
                f"Pipeline did not complete — {reason}"),
            duration_ms=proc_call.wall_ms, where="cloud", budget=BUDGET_DEVICE,
            data={"error": reason, "detection_disagreement": detection_disagreement},
        ))
        run.fail_ref = "FP-01" if detection_disagreement else "FP-05"
        run.fail_reason = reason
        run.timings = {"wall_ms": wall_total, "quality_check_ms": qc_call.wall_ms,
                       "process_ms": proc_call.wall_ms}
        return run

    liveness = proc.get("liveness") or {}
    run.liveness = liveness
    bypassed = bool(liveness.get("note") or liveness.get("error"))
    is_live = bool(liveness.get("is_live"))

    if bypassed:
        live_status, live_summary = "warn", (
            f"Liveness check did not run — {liveness.get('note') or liveness.get('error')}")
    elif is_live:
        live_status = "pass"
        live_summary = f"Live finger, confidence {float(liveness.get('confidence', 0.0)):.2f}"
    else:
        live_status = "fail"
        live_summary = f"Spoof suspected, confidence {float(liveness.get('confidence', 0.0)):.2f}"

    # /process runs liveness, segmentation, enhancement and minutiae extraction in one
    # request and times none of them individually. Attributing the whole round trip to
    # liveness would overstate it by an order of magnitude, so the call is billed to
    # FP-05 below and this stage carries no time of its own.
    run.stages.append(Stage(
        ref="FP-02", title="Basic Liveness", status=live_status, summary=live_summary,
        duration_ms=0.0, where="cloud", budget=BUDGET_DEVICE,
        data={"liveness": liveness, "bypassed": bypassed},
    ))

    # ── FP-04 Multi-finger — out of scope for this single-finger bench ───────
    run.stages.append(Stage(
        ref="FP-04", title="Multi-Finger Capture", status="skip",
        summary="Single-finger bench. Slap capture lives in slap_app.py on port 5010 "
                "and is not exercised here.",
        where="n/a", budget=BUDGET_DEVICE,
    ))

    # ── FP-05 Preprocessing ──────────────────────────────────────────────────
    images = proc.get("images") or {}
    for key in ("original", "cropped", "preprocessed", "visualization"):
        pil = _b64_to_pil(images.get(key))
        if pil is not None:
            run.images[key] = pil

    server_qc = proc.get("quality") or {}
    run.stages.append(Stage(
        ref="FP-05", title="Preprocessing Pipeline",
        status="pass" if "preprocessed" in run.images else "fail",
        summary=("Contact-equivalent image produced — U²-Net mask, Zero-DCE or "
                 "histogram equalisation, adaptive threshold. The time shown covers the "
                 "whole /process call: liveness, segmentation, enhancement and minutiae "
                 "extraction together."
                 if "preprocessed" in run.images else "No preprocessed image returned"),
        duration_ms=proc_call.wall_ms,        # the one call that covers FP-02 and FP-05
        where="cloud", budget=BUDGET_DEVICE,
        data={"detection_conf": proc.get("detection_conf"),
              "server_quality_gate": server_qc},
    ))

    minutiae = proc.get("minutiae") or []
    run.minutiae = minutiae

    # ── FP-06 Template generation (ISO/IEC 19794-4 FIR) ─────────────────────
    # Prefer the backend's /export_fir so the record comes from the deployed system.
    # That endpoint arrived with the FIR encoder commit, so a server running older code
    # answers 404 — in which case fall back to encoding here with the same fir.py the
    # backend would have used. The stage reports which of the two produced the record.
    fir_call = client.export_fir(base_url, image_bytes, finger_position=finger_position,
                                 source_dpi=source_dpi, filename=filename)
    wall_total += fir_call.wall_ms

    if fir_call.succeeded:
        info = _fir_from_server(fir_call, finger_position)
    else:
        info = _fir_locally(images.get("preprocessed"), finger_position, source_dpi)
        info["server_error"] = fir_call.error
        info["server_status"] = fir_call.status

    run.fir = info
    if info.get("decoded_image") is not None:
        run.images["fir_decoded"] = info.pop("decoded_image")
    else:
        info.pop("decoded_image", None)

    if info.get("record") is None:
        run.stages.append(Stage(
            ref="FP-06", title="Template Generation", status="fail",
            summary=f"No FIR record produced — {info.get('error', 'unknown error')}",
            duration_ms=fir_call.wall_ms, where="cloud", budget=BUDGET_DEVICE,
            data=info,
        ))
    else:
        where_label = ("the backend's /export_fir" if info["source"] == "server"
                       else "fir.py, locally in the bench")
        run.stages.append(Stage(
            ref="FP-06", title="Template Generation",
            status="pass" if info["roundtrip_ok"] else "fail",
            summary=(f"{info['record_bytes']:,} byte record, {info['width']}×{info['height']} @ "
                     f"{info['resolution_dpi']} dpi, uncompressed — encoded by {where_label}"
                     + (", decodes back cleanly" if info["roundtrip_ok"]
                        else f". Round trip FAILED: {info['roundtrip_error']}")),
            duration_ms=fir_call.wall_ms if info["source"] == "server" else info["encode_ms"],
            server_ms=(info.get("pipeline_metrics") or {}).get("total_time_ms"),
            where="cloud" if info["source"] == "server" else "local",
            budget=BUDGET_DEVICE,
            data=info,
        ))

    # ── Result ───────────────────────────────────────────────────────────────
    run.timings = {
        "wall_ms": wall_total,
        "quality_check_ms": qc_call.wall_ms,
        "process_ms": proc_call.wall_ms,
        "export_fir_ms": fir_call.wall_ms if run.fir.get("source") == "server" else 0.0,
        "local_fir_ms": run.fir.get("encode_ms") or 0.0,
        "server_quality_ms": qc.get("elapsed_ms"),
        "server_fir_ms": (run.fir.get("pipeline_metrics") or {}).get("total_time_ms"),
    }

    if not minutiae:
        run.fail_ref, run.fail_reason = "FP-06", "No minutiae extracted"
    elif len(minutiae) < MIN_MINUTIAE:
        run.fail_ref = "FP-06"
        run.fail_reason = (f"Only {len(minutiae)} minutiae — /enroll rejects anything "
                           f"under {MIN_MINUTIAE}")
    else:
        run.ok = True

    return run


def budget_totals(run: PipelineRun) -> dict:
    """
    Wall-clock split by which side of the spec budget each stage belongs to.

    These are round-trip times to a server, not on-device times. Nothing in this repo
    runs the pipeline on a phone yet, so the on-device figure remains unmeasured — the
    number below is the closest honest proxy and is labelled as such in the UI.
    """
    device_ms = sum(s.duration_ms for s in run.stages if s.budget == BUDGET_DEVICE)
    server_ms = sum(v for v in (run.timings.get("server_quality_ms"),
                                run.timings.get("server_fir_ms")) if v)
    local_ms = run.timings.get("local_fir_ms") or 0.0
    return {
        "device_wall_ms": device_ms,
        "server_compute_ms": server_ms,
        "local_compute_ms": local_ms,
        # Whatever is left after the compute either side reported: transport, queueing,
        # and the server-side work no endpoint bothers to time.
        "network_ms": max(0.0, device_ms - server_ms - local_ms),
        "total_wall_ms": run.timings.get("wall_ms", device_ms),
    }
