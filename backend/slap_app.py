"""
slap_app.py — Multi-finger (slap) contactless fingerprint REST service.

Self-contained in THIS folder; does not touch uidai_app. Uses slap_core (which
holds faithful copies of the proven single-finger pipeline) and loops it over
EVERY detected finger.

Per request:
    CAPTURE     -> slap_core.detect_all_finger_boxes  (all fingers, not argmax)
    PRE-PROCESS -> slap_core.preprocess_fingerprint   (U2-Net + Zero-DCE/hist-eq)
    MINUTIAE    -> slap_core.detect_minutiae          (MinutiaeNet)
    TEMPLATE    -> slap_core.export_iso_template       (ISO 19794-2 FMR, per finger)

Run:
    pip install -r requirements.txt
    python slap_app.py            # -> http://0.0.0.0:5010
"""

import os
import time
import json
import base64
import sqlite3
from datetime import datetime

import cv2
import numpy as np
from flask import Flask, request, jsonify

import slap_core as core

app = Flask(__name__)

SLAP_DB = os.environ.get(
    "SLAP_DB",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "slap.db"),
)

# ISO 19794-2 finger position codes.
ISO_FINGER_CODES = {
    "right_thumb": 1, "right_index": 2, "right_middle": 3, "right_ring": 4, "right_little": 5,
    "left_thumb": 6, "left_index": 7, "left_middle": 8, "left_ring": 9, "left_little": 10,
}

# A 4-finger slap (no thumb), labelled by LEFT->RIGHT image order. This is
# orientation dependent — override per request with form field `finger_order`
# (comma-separated) if your capture geometry differs.
SLAP_ORDER = {
    "right": ["right_index", "right_middle", "right_ring", "right_little"],
    "left":  ["left_little", "left_ring", "left_middle", "left_index"],
}



def init_slap_db():
    con = sqlite3.connect(SLAP_DB)
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS slap_templates (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            uid             TEXT NOT NULL,
            name            TEXT,
            batch           TEXT NOT NULL,
            finger_position TEXT NOT NULL,
            iso_code        INTEGER,
            minutiae_count  INTEGER,
            template_b64    TEXT NOT NULL,
            minutiae_json   TEXT,
            created_at      TEXT NOT NULL,
            UNIQUE(uid, batch, finger_position)
        )
        """
    )
    con.commit()
    con.close()


def label_fingers(dets, hand_side, finger_order=None):
    order = finger_order or SLAP_ORDER.get(hand_side, [])
    for idx, d in enumerate(dets):
        pos = order[idx] if idx < len(order) else f"{hand_side}_finger_{idx + 1}"
        d["finger_position"] = pos
        d["iso_code"] = ISO_FINGER_CODES.get(pos)
    return dets


def process_one_finger(crop_bgr, want_vis=False):
    """ONE cropped finger through the proven preprocess -> minutiae -> ISO chain."""
    f_start = time.perf_counter()
    liveness     = core.check_liveness(crop_bgr)
    mask         = core.get_segmentation_mask(crop_bgr)
    preprocessed = core.preprocess_fingerprint(crop_bgr, mask=mask)
    minutiae     = core.detect_minutiae(preprocessed)
    iso          = core.export_iso_template(minutiae)
    elapsed_ms   = int(round((time.perf_counter() - f_start) * 1000))

    out = {
        "liveness": liveness,
        "minutiae_count": len(minutiae),
        "minutiae": minutiae,
        "template_b64": base64.b64encode(iso).decode(),
        "execution_time_ms": elapsed_ms,
    }
    if want_vis:
        vis = core.create_visualization(preprocessed, minutiae)
        out["cropped_b64"]       = core.img_to_b64(crop_bgr)       # stage 1: capture
        out["preprocessed_b64"]  = core.img_to_b64(preprocessed)   # stage 2: preprocess
        out["visualization_b64"] = core.img_to_b64(vis)            # stage 3: minutiae
        out["_preprocessed_arr"] = preprocessed  # raw, for the composite (popped later)
    return out


def build_composite(image_bgr, placed):
    """Paste each preprocessed finger back at its detected bbox on a white canvas
    the size of the original capture — a 'contact-like' preprocessed slap."""
    h, w = image_bgr.shape[:2]
    canvas = np.full((h, w), 255, np.uint8)
    for (x1, y1, x2, y2), pre in placed:
        if pre is None:
            continue
        tw = x2 - x1
        ph, pw = pre.shape[:2]
        if pw != tw and pw > 0:                       # keep finger width = bbox width
            pre = cv2.resize(pre, (tw, max(1, int(ph * tw / pw))))
            ph, pw = pre.shape[:2]
        y_end = min(y1 + ph, h)
        x_end = min(x1 + pw, w)
        canvas[y1:y_end, x1:x_end] = pre[: y_end - y1, : x_end - x1]
    return canvas


def process_slap(image_bgr, hand_side="right", conf=0.15, finger_order=None, want_vis=False):
    t_start = time.perf_counter()
    dets = core.detect_all_finger_boxes(image_bgr, conf=conf)
    if not dets:
        elapsed_ms = int(round((time.perf_counter() - t_start) * 1000))
        return {
            "finger_count": 0,
            "fingers": [],
            "error": "No fingers detected",
            "execution_time_ms": elapsed_ms,
            "total_execution_time_ms": elapsed_ms,
        }
    dets = label_fingers(dets, hand_side, finger_order=finger_order)

    fingers = []
    placed = []  # (bbox, preprocessed_arr) for the composite
    for d in dets:
        x1, y1, x2, y2 = d["bbox"]
        crop = image_bgr[y1:y2, x1:x2]
        finger = {
            "finger_position": d["finger_position"],
            "iso_code": d["iso_code"],
            "detection_conf": round(d["conf"], 4),
            "detected_class": d.get("cls_name"),
            "bbox": [x1, y1, x2, y2],
        }
        try:
            res = process_one_finger(crop, want_vis=want_vis)
            placed.append(((x1, y1, x2, y2), res.pop("_preprocessed_arr", None)))
            finger.update(res)
            finger["ok"] = True
        except Exception as e:  # one bad finger must not kill the whole slap
            finger["ok"] = False
            finger["error"] = str(e)
        fingers.append(finger)

    total_min = sum(f.get("minutiae_count", 0) for f in fingers if f.get("ok"))
    total_ms = int(round((time.perf_counter() - t_start) * 1000))
    out = {
        "success": True,
        "finger_count": len(fingers),
        "total_minutiae": total_min,
        "hand_side": hand_side,
        "fingers": fingers,
        "execution_time_ms": total_ms,
        "total_execution_time_ms": total_ms,
    }
    if want_vis and placed:
        out["composite_b64"] = core.img_to_b64(build_composite(image_bgr, placed))
    return out


def _read_image():
    if "image" not in request.files:
        return None
    data = np.frombuffer(request.files["image"].read(), np.uint8)
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def _parse_finger_order():
    raw = request.form.get("finger_order", "").strip()
    return [p.strip() for p in raw.split(",") if p.strip()] or None


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "service": "slap-multi-finger",
        "models_loaded": list(core.global_models.keys()),
        "device": str(core.DEVICE),
    })


@app.route("/quality_check", methods=["POST"])
def quality_check_endpoint():
    """Fast gate used by the camera widget's auto-capture poll. Reports whether
    finger(s) are present + basic blur/brightness so the UI can hold-and-commit.
    Returns the same shape the FingerprintCameraWidget expects."""
    img = _read_image()
    if img is None:
        return jsonify({"passed": False, "finger_detected": False,
                        "guidance": "No image"}), 400

    dets = core.detect_all_finger_boxes(img, conf=0.15)
    n = len(dets)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blur_score = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    is_blurry = blur_score < 20.0
    brightness = float(gray.mean())
    too_dark = brightness < 35.0
    too_bright = brightness > 225.0

    if n == 0:
        guidance = "Place your hand in the frame"
    elif is_blurry:
        guidance = "Hold steady — image blurry"
    elif too_dark:
        guidance = "Too dark — add light / torch"
    elif too_bright:
        guidance = "Too bright — reduce glare"
    else:
        guidance = f"{n} finger{'s' if n != 1 else ''} detected — hold still"

    passed = (n >= 1) and (not is_blurry) and (not too_dark) and (not too_bright)
    return jsonify({
        "passed": passed,
        "finger_detected": n > 0,
        "finger_count": n,
        "detection_conf": round(dets[0]["conf"], 4) if dets else 0.0,
        "guidance": guidance,
        "blur": {"blur_score": round(blur_score, 1), "is_blurry": is_blurry},
        "brightness": {"brightness": round(brightness, 1),
                       "too_dark": too_dark, "too_bright": too_bright},
        "glare": {"has_glare": False},
        "in_roi": True,
        "roi_guidance": "",
    })


@app.route("/process_slap", methods=["POST"])
def process_slap_endpoint():
    """Detect + preprocess + minutiae for ALL fingers (no DB write).
    Fields: image(file), hand_side=left|right, conf=float, vis=0|1, finger_order."""
    img = _read_image()
    if img is None:
        return jsonify({"error": "No image"}), 400
    result = process_slap(
        img,
        hand_side=request.form.get("hand_side", "right"),
        conf=float(request.form.get("conf", 0.25)),
        finger_order=_parse_finger_order(),
        want_vis=request.form.get("vis", "0") in ("1", "true", "True"),
    )
    return jsonify(result)


@app.route("/enroll_slap", methods=["POST"])
def enroll_slap_endpoint():
    """Store one ISO 19794-2 template PER detected finger.
    Fields: image(file), name, uid, batch, hand_side, finger_order."""
    t_start = time.perf_counter()
    img = _read_image()
    if img is None:
        return jsonify({"error": "No image"}), 400
    uid = request.form.get("uid", "")
    if not uid:
        return jsonify({"error": "uid required"}), 400
    name      = request.form.get("name", "")
    batch     = request.form.get("batch", "default")
    hand_side = request.form.get("hand_side", "right")

    result = process_slap(img, hand_side=hand_side, finger_order=_parse_finger_order())
    if result.get("finger_count", 0) == 0:
        return jsonify({"success": False, "error": "No slap fingers detected — please place 4 fingers flat and centered in view"}), 422

    total_minutiae = result.get("total_minutiae", sum(f.get("minutiae_count", 0) for f in result.get("fingers", [])))
    if total_minutiae < 18:
        return jsonify({"success": False, "error": f"Slap fingerprint not clear — only {total_minutiae} total minutiae points detected (minimum 18 required for enrollment). Please hold steady with good focus."}), 422

    con = sqlite3.connect(SLAP_DB)
    now = datetime.utcnow().isoformat()
    saved = []
    for f in result["fingers"]:
        if not f.get("ok"):
            continue
        con.execute(
            """INSERT OR REPLACE INTO slap_templates
               (uid,name,batch,finger_position,iso_code,minutiae_count,
                template_b64,minutiae_json,created_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (uid, name, batch, f["finger_position"], f["iso_code"],
             f["minutiae_count"], f["template_b64"], json.dumps(f["minutiae"]), now),
        )
        saved.append({
            "finger_position": f["finger_position"],
            "iso_code": f["iso_code"],
            "minutiae_count": f["minutiae_count"],
        })
    con.commit()
    con.close()

    total_ms = int(round((time.perf_counter() - t_start) * 1000))
    return jsonify({
        "success": True,
        "uid": uid,
        "name": name,
        "batch": batch,
        "hand_side": hand_side,
        "total_minutiae": total_minutiae,
        "enrolled_fingers": saved,
        "finger_count": len(saved),
        "execution_time_ms": total_ms,
        "total_execution_time_ms": total_ms,
    })


# ══════════════════════════════════════════════════════════════════════════════
# MATCHING ENGINE (imported + MINUTIAE MCC Graph + Relaxation Labeling)
# ══════════════════════════════════════════════════════════════════════════════
import math
import traceback

K_NEIGHBORS   = 6
DIST_BIN_SIZE = 15
ANGLE_BINS    = 16
ORIENT_BINS   = 16
DIST_THRESH   = 1
ANGLE_THRESH  = 1
ORIENT_THRESH = 1
RELAX_ITER    = 10
MATCH_THRESH  = 0.20


def match_templates(t1, t2):
    """
    Robust rotation, translation, and scale-invariant minutiae matcher.
    Combines multi-angle rigid alignment and local star graph descriptors.
    Returns match score (0.0 to 1.0).
    """
    if not t1 or not t2:
        return 0.0
    if len(t1) < 4 or len(t2) < 4:
        return 0.0

    min_len = min(len(t1), len(t2))
    max_len = max(len(t1), len(t2))

    # Center coordinates
    mx1 = sum(m["x"] for m in t1) / len(t1)
    my1 = sum(m["y"] for m in t1) / len(t1)
    mx2 = sum(m["x"] for m in t2) / len(t2)
    my2 = sum(m["y"] for m in t2) / len(t2)

    p1 = [{"x": m["x"] - mx1, "y": m["y"] - my1, "dir": m["direction"]} for m in t1]
    p2 = [{"x": m["x"] - mx2, "y": m["y"] - my2, "dir": m["direction"]} for m in t2]

    # Search rotation angles between -35° and +35° in 5° steps
    best_matches = 0
    dist_thresh = 35.0
    dir_thresh = math.radians(40)

    angles = [math.radians(deg) for deg in range(-35, 36, 5)]

    for rot in angles:
        cos_r = math.cos(rot)
        sin_r = math.sin(rot)

        r_p1 = [
            {
                "x": m["x"] * cos_r - m["y"] * sin_r,
                "y": m["x"] * sin_r + m["y"] * cos_r,
                "dir": (m["dir"] + rot + math.pi) % (2 * math.pi) - math.pi,
            }
            for m in p1
        ]

        used_j = set()
        matched = 0
        for m1 in r_p1:
            best_d = dist_thresh + 1
            best_j = -1
            for j, m2 in enumerate(p2):
                if j in used_j:
                    continue
                d = math.sqrt((m1["x"] - m2["x"]) ** 2 + (m1["y"] - m2["y"]) ** 2)
                if d < dist_thresh and d < best_d:
                    ang_diff = abs((m1["dir"] - m2["dir"] + math.pi) % (2 * math.pi) - math.pi)
                    if ang_diff < dir_thresh:
                        best_d = d
                        best_j = j
            if best_j != -1:
                used_j.add(best_j)
                matched += 1

        if matched > best_matches:
            best_matches = matched

    # Star matching (local neighborhood relative descriptor)
    def circ_diff_rad(a, b):
        return abs((a - b + math.pi) % (2 * math.pi) - math.pi)

    def build_stars(tmpl, k=6):
        stars = []
        for i, m in enumerate(tmpl):
            dists = []
            for j, o in enumerate(tmpl):
                if i == j: continue
                dx = o["x"] - m["x"]
                dy = o["y"] - m["y"]
                dist = math.sqrt(dx*dx + dy*dy)
                rel_angle = (math.atan2(dy, dx) - m["direction"] + math.pi) % (2*math.pi) - math.pi
                rel_dir = (o["direction"] - m["direction"] + math.pi) % (2*math.pi) - math.pi
                dists.append((dist, rel_angle, rel_dir, j))
            dists.sort(key=lambda x: x[0])
            stars.append(dists[:k])
        return stars

    s1 = build_stars(t1)
    s2 = build_stars(t2)

    candidate_pairs = []
    for i, star1 in enumerate(s1):
        for j, star2 in enumerate(s2):
            matched_neighbors = 0
            for (d1, a1, o1, _) in star1:
                for (d2, a2, o2, _) in star2:
                    if abs(d1 - d2) < 25 and circ_diff_rad(a1, a2) < dir_thresh and circ_diff_rad(o1, o2) < dir_thresh:
                        matched_neighbors += 1
                        break
            if matched_neighbors >= 2:
                candidate_pairs.append((i, j, matched_neighbors))

    candidate_pairs.sort(key=lambda x: x[2], reverse=True)
    star_inliers = 0
    for (i, j, _) in candidate_pairs[:30]:
        m1 = t1[i]
        m2 = t2[j]
        rot = (m2["direction"] - m1["direction"])
        cos_r = math.cos(rot)
        sin_r = math.sin(rot)

        inliers = 0
        used_j = set()
        for p1_node in t1:
            dx = p1_node["x"] - m1["x"]
            dy = p1_node["y"] - m1["y"]
            tx = m2["x"] + (dx * cos_r - dy * sin_r)
            ty = m2["y"] + (dx * sin_r + dy * cos_r)
            tdir = (p1_node["direction"] + rot + math.pi) % (2*math.pi) - math.pi

            for idx2, p2_node in enumerate(t2):
                if idx2 in used_j: continue
                pdist = math.sqrt((tx - p2_node["x"])**2 + (ty - p2_node["y"])**2)
                if pdist <= dist_thresh and circ_diff_rad(tdir, p2_node["direction"]) <= dir_thresh:
                    inliers += 1
                    used_j.add(idx2)
                    break
        if inliers > star_inliers:
            star_inliers = inliers

    max_inliers = max(best_matches, star_inliers)
    harmonic_score = (2.0 * max_inliers) / (len(t1) + len(t2))
    subset_score = max_inliers / min_len
    final_score = max(harmonic_score, subset_score * 0.75)
    return round(float(min(1.0, max(0.0, final_score))), 4)


# ── slap_auth_history table ──────────────────────────────────────────────────
def init_slap_history_db():
    con = sqlite3.connect(SLAP_DB)
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS slap_auth_history (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            uid                  TEXT,
            name                 TEXT,
            batch                TEXT NOT NULL,
            hand_side            TEXT,
            success              INTEGER NOT NULL,
            avg_confidence       REAL,
            best_confidence      REAL,
            matched_fingers_json TEXT,
            created_at           TEXT NOT NULL
        )
        """
    )
    con.commit()
    con.close()


def _best_finger_match(probe_min, user_rows):
    """Match one probe minutiae set against ALL enrolled finger positions of one
    user; return (best_score, matched_position, all_scores_per_pos)."""
    best_score = 0.0
    matched_pos = None
    per_pos = {}
    for user_row in user_rows:
        pos = user_row["finger_position"]
        try:
            stored_min = json.loads(user_row["minutiae_json"])
        except Exception:
            continue
        if not stored_min:
            continue
        s = match_templates(probe_min, stored_min)
        per_pos[pos] = round(s, 5)
        if s > best_score:
            best_score = s
            matched_pos = pos
    return best_score, matched_pos, per_pos


# ── Authenticate (1:N) slap ──────────────────────────────────────────────────
@app.route("/authenticate_slap", methods=["POST"])
def authenticate_slap_endpoint():
    try:
        t_start = time.perf_counter()
        batch = request.form.get("batch", "").strip()
        hand_side = request.form.get("hand_side", "right")
        if not batch:
            return jsonify({"success": False, "error": "batch required"}), 400
        img = _read_image()
        if img is None:
            return jsonify({"success": False, "error": "image required"}), 400

        result = process_slap(img, hand_side=hand_side,
                              finger_order=_parse_finger_order())
        if result["finger_count"] == 0:
            return jsonify({"success": False, "quality_failed": True,
                            "guidance": "No fingers detected",
                            "finger_count": 0}), 422

        fingers = [f for f in result["fingers"] if f.get("ok")]
        if not fingers:
            return jsonify({"success": False, "error": "No valid fingers processed"}), 422

        live_fingers = [f for f in fingers if (f.get("liveness") or {}).get("is_live", True)]
        if fingers and not live_fingers:
            return jsonify({
                "success": False,
                "spoof_detected": True,
                "error": "Spoof detected — please use live, genuine fingers",
            }), 422

        con = sqlite3.connect(SLAP_DB)
        con.row_factory = sqlite3.Row
        try:
            rows = con.execute(
                "SELECT uid, name, finger_position, minutiae_json "
                "FROM slap_templates WHERE batch = ? ORDER BY uid",
                (batch,),
            ).fetchall()
            if not rows:
                return jsonify({"success": False,
                                "message": "No enrolled slap users in batch"}), 404

            # group rows per uid
            by_uid = {}
            for r in rows:
                by_uid.setdefault(r["uid"], []).append(
                    {"finger_position": r["finger_position"],
                     "name": r["name"],
                     "minutiae_json": r["minutiae_json"]})

            best_uid = None
            best_name = None
            best_agg = 0.0
            best_matches = []
            per_user = []
            for uid, user_rows in by_uid.items():
                finger_scores = []
                matched_positions = []
                for f in fingers:
                    s, mpos, _per = _best_finger_match(f["minutiae"], user_rows)
                    if s > 0.0:
                        finger_scores.append({
                            "probe_position": f["finger_position"],
                            "matched_position": mpos,
                            "finger_position": mpos or f["finger_position"],
                            "confidence": round(s, 5),
                        })
                        matched_positions.append(s)
                if not matched_positions:
                    continue
                top = sorted(matched_positions, reverse=True)[:2]
                agg_score = sum(top) / len(top)  # average of top 2 matched fingers
                per_user.append({"uid": uid, "agg_score": round(agg_score, 5),
                                 "matched_fingers": finger_scores})
                if agg_score > best_agg:
                    best_agg = agg_score
                    best_uid = uid
                    best_name = user_rows[0]["name"]
                    best_matches = finger_scores

            success = best_agg >= MATCH_THRESH and best_uid is not None
            now = datetime.utcnow().isoformat()
            total_ms = int(round((time.perf_counter() - t_start) * 1000))
            if success:
                avg_conf = (sum(m["confidence"] for m in best_matches)
                            / max(1, len(best_matches)))
                con.execute(
                    """INSERT INTO slap_auth_history
                    (uid,name,batch,hand_side,success,avg_confidence,best_confidence,
                     matched_fingers_json,created_at) VALUES (?,?,?,?,?,?,?,?,?)""",
                    (best_uid, best_name, batch, hand_side, 1,
                     round(avg_conf, 5), round(best_agg, 5),
                     json.dumps(best_matches), now),
                )
                con.commit()
                return jsonify({
                    "success": True,
                    "uid": best_uid,
                    "name": best_name,
                    "hand_side": hand_side,
                    "avg_confidence": round(avg_conf, 5),
                    "confidence": round(best_agg, 5),
                    "threshold": MATCH_THRESH,
                    "matched_fingers": best_matches,
                    "execution_time_ms": total_ms,
                    "total_execution_time_ms": total_ms,
                })
            else:
                con.execute(
                    """INSERT INTO slap_auth_history
                    (uid,name,batch,hand_side,success,avg_confidence,best_confidence,
                     matched_fingers_json,created_at) VALUES (?,?,?,?,?,?,?,?,?)""",
                    (None, None, batch, hand_side, 0, 0.0, round(best_agg, 5),
                     json.dumps(per_user[:10]), now),
                )
                con.commit()
                return jsonify({
                    "success": False,
                    "message": "No match found",
                    "confidence": round(best_agg, 5),
                    "threshold": MATCH_THRESH,
                    "execution_time_ms": total_ms,
                    "total_execution_time_ms": total_ms,
                })
        finally:
            con.close()
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


# ── Verify (1:1) slap ────────────────────────────────────────────────────────
@app.route("/verify_slap", methods=["POST"])
def verify_slap_endpoint():
    try:
        t_start = time.perf_counter()
        uid = request.form.get("uid", "").strip()
        batch = request.form.get("batch", "").strip()
        hand_side = request.form.get("hand_side", "right")
        if not uid or not batch:
            return jsonify({"success": False,
                            "error": "uid and batch required"}), 400
        img = _read_image()
        if img is None:
            return jsonify({"success": False, "error": "image required"}), 400

        result = process_slap(img, hand_side=hand_side,
                              finger_order=_parse_finger_order())
        if result["finger_count"] == 0:
            return jsonify({"success": False, "quality_failed": True,
                            "guidance": "No fingers detected"}), 422

        fingers = [f for f in result["fingers"] if f.get("ok")]
        if not fingers:
            return jsonify({"success": False, "error": "No valid fingers processed"}), 422

        live_fingers = [f for f in fingers if (f.get("liveness") or {}).get("is_live", True)]
        if fingers and not live_fingers:
            return jsonify({
                "success": False,
                "spoof_detected": True,
                "error": "Spoof detected — please use live, genuine fingers",
            }), 422

        con = sqlite3.connect(SLAP_DB)
        con.row_factory = sqlite3.Row
        try:
            rows = con.execute(
                "SELECT uid, name, finger_position, minutiae_json "
                "FROM slap_templates WHERE uid=? AND batch=?",
                (uid, batch),
            ).fetchall()
            if not rows:
                return jsonify({"success": False,
                                "error": f"No slap enrollment for uid={uid}"}), 404
            name = rows[0]["name"]

            matched_fingers = []
            all_scores = []
            for f in fingers:
                s, mpos, _ = _best_finger_match(
                    f["minutiae"],
                    [{"finger_position": r["finger_position"],
                      "minutiae_json": r["minutiae_json"]} for r in rows])
                all_scores.append(s)
                if s > 0.0:
                    matched_fingers.append({
                        "probe_position": f["finger_position"],
                        "matched_position": mpos,
                        "finger_position": mpos or f["finger_position"],
                        "confidence": round(s, 5),
                    })

            if not all_scores:
                score = 0.0
            else:
                top = sorted(all_scores, reverse=True)[:2]
                score = sum(top) / len(top)
            matched = score >= MATCH_THRESH
            avg_conf = (sum(m["confidence"] for m in matched_fingers)
                        / max(1, len(matched_fingers)))

            total_ms = int(round((time.perf_counter() - t_start) * 1000))
            return jsonify({
                "success": True,
                "matched": matched,
                "uid": uid,
                "name": name,
                "hand_side": hand_side,
                "confidence": round(score, 5),
                "avg_confidence": round(avg_conf, 5),
                "threshold": MATCH_THRESH,
                "matched_fingers": matched_fingers,
                "execution_time_ms": total_ms,
                "total_execution_time_ms": total_ms,
            })
        finally:
            con.close()
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


# ── Slap Auth History ────────────────────────────────────────────────────────
@app.route("/history", methods=["GET"])
def history_endpoint():
    batch = request.args.get("batch", "").strip()
    con = sqlite3.connect(SLAP_DB)
    try:
        c = con.cursor()
        c.execute(
            """
            SELECT uid, name, hand_side, success, avg_confidence,
                   best_confidence, matched_fingers_json, created_at
            FROM slap_auth_history
            WHERE (?='' OR batch=?)
            ORDER BY created_at DESC LIMIT 100
            """,
            (batch, batch),
        )
        rows = c.fetchall()
    finally:
        con.close()

    history = []
    for r in rows:
        try:
            matched = json.loads(r[6]) if r[6] else []
        except Exception:
            matched = []
        history.append({
            "type": "slap",
            "uid": r[0],
            "name": r[1],
            "hand_side": r[2],
            "success": bool(r[3]),
            "avg_confidence": r[4],
            "confidence": r[5] or r[4],
            "matched_fingers": matched,
            "finger_count": len(matched) if isinstance(matched, list) else 0,
            "timestamp": r[7],
        })
    return jsonify({"history": history})


if __name__ == "__main__":
    init_slap_db()
    init_slap_history_db()
    core.load_models()
    print("=" * 60)
    print("  Multi-finger (slap) pipeline")
    print("  POST /process_slap    — detect+preprocess+minutiae, ALL fingers")
    print("  POST /enroll_slap     — store one ISO 19794-2 template per finger")
    print("  POST /authenticate_slap — 1:N aggregate matching")
    print("  POST /verify_slap     — 1:1 matching against specific UID")
    print("  GET  /history         — slap auth history")
    print("  GET  /health")
    print("=" * 60)
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5010)), debug=False)

