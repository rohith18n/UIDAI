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
    "right": ["right_little", "right_ring", "right_middle", "right_index"],
    "left":  ["left_index", "left_middle", "left_ring", "left_little"],
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
    liveness     = core.check_liveness(crop_bgr)
    mask         = core.get_segmentation_mask(crop_bgr)
    preprocessed = core.preprocess_fingerprint(crop_bgr, mask=mask)
    minutiae     = core.detect_minutiae(preprocessed)
    iso          = core.export_iso_template(minutiae)

    out = {
        "liveness": liveness,
        "minutiae_count": len(minutiae),
        "minutiae": minutiae,
        "template_b64": base64.b64encode(iso).decode(),
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


def process_slap(image_bgr, hand_side="right", conf=0.25, finger_order=None, want_vis=False):
    dets = core.detect_all_finger_boxes(image_bgr, conf=conf)
    if not dets:
        return {"finger_count": 0, "fingers": [], "error": "No fingers detected"}
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

    out = {"finger_count": len(fingers), "hand_side": hand_side, "fingers": fingers}
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

    dets = core.detect_all_finger_boxes(img, conf=0.25)
    n = len(dets)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blur_score = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    is_blurry = blur_score < 60.0
    brightness = float(gray.mean())
    too_dark = brightness < 55.0
    too_bright = brightness > 205.0

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
    if result["finger_count"] == 0:
        return jsonify(result), 422

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

    return jsonify({
        "uid": uid, "name": name, "batch": batch, "hand_side": hand_side,
        "enrolled_fingers": saved, "finger_count": len(saved),
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
MATCH_THRESH  = 0.25


def _angle_to_bin(theta, bins):
    return int((theta % (2 * math.pi)) / (2 * math.pi) * bins)


def _circ_diff(a, b, bins):
    d = abs(a - b)
    return min(d, bins - d)


def _euclidean(p1, p2):
    return math.sqrt((p1["x"] - p2["x"]) ** 2 + (p1["y"] - p2["y"]) ** 2)


def _compute_edge(p1, p2):
    dx = p2["x"] - p1["x"]
    dy = p2["y"] - p1["y"]
    dist = math.sqrt(dx * dx + dy * dy)
    return (
        int(dist / DIST_BIN_SIZE),
        _angle_to_bin(math.atan2(dy, dx), ANGLE_BINS),
        (_angle_to_bin(p2["direction"], ORIENT_BINS) -
         _angle_to_bin(p1["direction"], ORIENT_BINS)) % ORIENT_BINS,
    )


def _build_graph(tmpl):
    edges = {}
    for i in range(len(tmpl)):
        dists = sorted([((_euclidean(tmpl[i], tmpl[j])), j)
                        for j in range(len(tmpl)) if j != i])
        for _, j in dists[:K_NEIGHBORS]:
            edges[(i, j)] = _compute_edge(tmpl[i], tmpl[j])
    return edges


def _node_compat(n1, n2):
    if n1["type"] != n2["type"]:
        return False
    if _circ_diff(_angle_to_bin(n1["direction"], ORIENT_BINS),
                  _angle_to_bin(n2["direction"], ORIENT_BINS),
                  ORIENT_BINS) > ORIENT_THRESH:
        return False
    if math.sqrt((n1["x"] - n2["x"]) ** 2 + (n1["y"] - n2["y"]) ** 2) > 25:
        return False
    return True


def _edge_compat(e1, e2):
    d1, a1, o1 = e1
    d2, a2, o2 = e2
    if abs(d1 - d2) > DIST_THRESH:
        return 0
    if _circ_diff(a1, a2, ANGLE_BINS) > ANGLE_THRESH:
        return 0
    if _circ_diff(o1, o2, ORIENT_BINS) > ORIENT_THRESH:
        return 0
    return math.exp(
        -(abs(d1 - d2) + _circ_diff(a1, a2, ANGLE_BINS) +
          _circ_diff(o1, o2, ORIENT_BINS)))


def _normalize(tmpl):
    if not tmpl:
        return tmpl
    mx = sum(m["x"] for m in tmpl) / len(tmpl)
    my = sum(m["y"] for m in tmpl) / len(tmpl)
    return [{**m, "x": m["x"] - mx, "y": m["y"] - my} for m in tmpl]


def _scale(tmpl, target=200):
    if not tmpl:
        return tmpl
    xs = [m["x"] for m in tmpl]
    ys = [m["y"] for m in tmpl]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1)
    f = target / span
    return [{**m, "x": m["x"] * f, "y": m["y"] * f} for m in tmpl]


def match_templates(t1, t2):
    """MCC graph + relaxation labeling minutiae matcher (0.0–1.0)."""
    if not t1 or not t2:
        return 0.0
    ratio = min(len(t1), len(t2)) / max(len(t1), len(t2))
    if ratio < 0.45:
        return 0.0
    t1 = _scale(_normalize(t1))
    t2 = _scale(_normalize(t2))
    e1 = _build_graph(t1)
    e2 = _build_graph(t2)
    cands = [(i, j) for i, n1 in enumerate(t1)
             for j, n2 in enumerate(t2) if _node_compat(n1, n2)]
    min_c = max(4, int(0.15 * min(len(t1), len(t2))))
    if len(cands) < min_c:
        return 0.0
    P = {c: 1.0 for c in cands}
    for _ in range(RELAX_ITER):
        Pn = {}
        for (i, j) in cands:
            total = sum(
                P[(k, l)] * _edge_compat(e1[(i, k)], e2[(j, l)])
                for (k, l) in cands if k != i and l != j
                and (i, k) in e1 and (j, l) in e2)
            Pn[(i, j)] = total
        norm = sum(Pn.values()) + 1e-6
        P = {k: v / norm for k, v in Pn.items()}
    used_i = set()
    used_j = set()
    matches = []
    for (i, j), s in sorted(P.items(), key=lambda x: -x[1]):
        if s < 0.001:
            continue
        if i not in used_i and j not in used_j:
            matches.append((i, j, s))
            used_i.add(i)
            used_j.add(j)
    if not matches:
        return 0.0
    score = 2 * len(matches) / (len(t1) + len(t2)) * ratio
    return float(max(0.0, min(1.0, score)))


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
        for f in fingers:
            lv = f.get("liveness") or {}
            if not lv.get("is_live"):
                return jsonify({
                    "success": False,
                    "spoof_detected": True,
                    "finger_position": f.get("finger_position"),
                    "liveness_confidence": lv.get("confidence", 0.0),
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
        for f in fingers:
            lv = f.get("liveness") or {}
            if not lv.get("is_live"):
                return jsonify({
                    "success": False,
                    "spoof_detected": True,
                    "finger_position": f.get("finger_position"),
                    "liveness_confidence": lv.get("confidence", 0.0),
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

