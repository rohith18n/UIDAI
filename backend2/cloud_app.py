"""
cloud_app.py — the cloud-only service: templatization + matching, nothing else.

Per the on-device/cloud split (see the architecture plan), on-device now owns
capture, quality control, liveness, and preprocessing (segmentation + enhancement)
for both single-finger and slap. This service receives the already-preprocessed
image(s) an on-device client produced, and does exactly two things to them:

    1. Templatization — detect_minutiae() (minutiae.py), the same MinutiaeNet
       both flows have always used.
    2. Matching — match_templates() (matching.py) for single-finger, or
       score_against_user() (slap_matching.py) for slap's per-finger aggregate.

Nothing here loads YOLO, liveness, U2Net, or Zero-DCE — those are on-device-tier
models this process never needs, which is the entire point of the split
(see requirements-cloud.txt). app.py and slap_app.py keep the full on-device-tier
reference pipeline for local development; this file is what actually deploys.

Routes are the SAME /v2/* endpoints already built and tested in app.py/slap_app.py
— moved here, not duplicated, so there is exactly one implementation of each.
"""

import base64
import json
import os
import sqlite3
import traceback
from datetime import datetime

import cv2
import numpy as np
from flask import Flask, request, jsonify
from flask_cors import CORS

from minutiae import detect_minutiae, get_minutiae_model
from matching import match_templates
from slap_matching import score_against_user, label_by_order, MATCH_THRESH

app = Flask(__name__)
CORS(app)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(BASE_DIR, "uploads")
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

DATABASE = os.environ.get("DATABASE", os.path.join(BASE_DIR, "uidai.db"))
SLAP_DB  = os.environ.get("SLAP_DB", os.path.join(BASE_DIR, "slap.db"))

SINGLE_THRESHOLD = 0.20
MATCHING_ALGORITHM = "legacy"


# ══════════════════════════════════════════════════════════════════════════════
# DATABASE — same schema as app.py's init_db() / slap_app.py's init_slap_db()
# ══════════════════════════════════════════════════════════════════════════════

def get_connection():
    conn = sqlite3.connect(DATABASE)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    conn = get_connection()
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT NOT NULL,
            uid         TEXT NOT NULL,
            batch       TEXT NOT NULL,
            template_json TEXT NOT NULL,
            created_at  TEXT NOT NULL,
            finger_position INTEGER NOT NULL DEFAULT 0
        )
    """)
    c.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_uid_batch_finger
            ON users(uid, batch, finger_position)
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS enrollments (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     INTEGER,
            timestamp   TEXT,
            minutiae_count INTEGER,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS authentications (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     INTEGER,
            timestamp   TEXT,
            confidence  REAL,
            matched     INTEGER,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
    """)
    conn.commit()
    conn.close()


def init_slap_db():
    con = sqlite3.connect(SLAP_DB)
    con.execute("""
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
    """)
    con.execute("""
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
    """)
    con.commit()
    con.close()


# ══════════════════════════════════════════════════════════════════════════════
# UPLOAD HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _save_upload(field_name="image"):
    f  = request.files[field_name]
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = os.path.join(UPLOAD_FOLDER, f"{ts}_{f.filename}")
    f.save(path)
    return path


def _read_images_list(field_name="image"):
    imgs = []
    for f in request.files.getlist(field_name):
        data = np.frombuffer(f.read(), np.uint8)
        img = cv2.imdecode(data, cv2.IMREAD_COLOR)
        if img is not None:
            imgs.append(img)
    return imgs


def _parse_finger_order():
    raw = request.form.get("finger_order", "").strip()
    return [p.strip() for p in raw.split(",") if p.strip()] or None


# ══════════════════════════════════════════════════════════════════════════════
# HEALTH
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/health", methods=["GET"])
def health():
    try:
        get_minutiae_model()
        minutiae_ok = True
    except Exception as e:
        minutiae_ok = str(e)
    return jsonify({
        "status": "ok",
        "service": "cloud-templatization-matching",
        "minutiae_model": minutiae_ok,
    })


# ══════════════════════════════════════════════════════════════════════════════
# SINGLE-FINGER — /v2/enroll, /v2/authenticate, /v2/verify
# Moved from app.py, unchanged.
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/v2/enroll", methods=["POST"])
def enroll_v2():
    try:
        name  = request.form.get("name", "").strip()
        uid   = request.form.get("uid", "").strip()
        batch = request.form.get("batch", "").strip()
        if not all([name, uid, batch]):
            return jsonify({"success": False, "error": "name, uid, batch required"}), 400
        if "image" not in request.files:
            return jsonify({"success": False, "error": "image required"}), 400

        try:
            finger_position = int(request.form.get("finger_position", 0))
        except ValueError:
            return jsonify({"success": False,
                            "error": "finger_position must be an integer 0-10"}), 400
        if not 0 <= finger_position <= 10:
            return jsonify({"success": False,
                            "error": "finger_position must be 0-10"}), 400

        path = _save_upload()
        preprocessed = cv2.imread(path)
        if preprocessed is None:
            return jsonify({"success": False, "error": "image could not be decoded"}), 400

        minutiae = detect_minutiae(preprocessed)
        if len(minutiae) < 5:
            return jsonify({"success": False, "error": "Too few minutiae — retake"}), 422

        conn = get_connection()
        try:
            c = conn.cursor()
            c.execute("""
                INSERT INTO users (name, uid, batch, template_json, created_at, finger_position)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(uid,batch,finger_position) DO UPDATE SET
                    name=excluded.name, template_json=excluded.template_json, created_at=excluded.created_at
            """, (name, uid, batch, json.dumps(minutiae), datetime.now().isoformat(),
                  finger_position))
            # lastrowid returns 0 when the upsert hits the UPDATE branch (no new
            # row) — always fetch the real id so the enrollments FK never fails.
            c.execute("SELECT id FROM users WHERE uid=? AND batch=? AND finger_position=?",
                      (uid, batch, finger_position))
            user_id = c.fetchone()[0]
            c.execute("INSERT INTO enrollments (user_id,timestamp,minutiae_count) VALUES (?,?,?)",
                      (user_id, datetime.now().isoformat(), len(minutiae)))
            conn.commit()
        finally:
            conn.close()

        return jsonify({"success": True, "minutiae_count": len(minutiae)})
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/v2/authenticate", methods=["POST"])
def authenticate_v2():
    try:
        batch = request.form.get("batch", "").strip()
        if not batch:
            return jsonify({"success": False, "error": "batch required"}), 400
        if "image" not in request.files:
            return jsonify({"success": False, "error": "image required"}), 400

        path = _save_upload()
        preprocessed = cv2.imread(path)
        if preprocessed is None:
            return jsonify({"success": False, "error": "image could not be decoded"}), 400

        input_minutiae = detect_minutiae(preprocessed)

        conn = get_connection()
        try:
            c = conn.cursor()
            c.execute("SELECT id,name,uid,template_json FROM users WHERE batch=?", (batch,))
            users = c.fetchall()
            if not users:
                return jsonify({"success": False, "message": "No users in this batch"})

            best_score = 0.0; best_user = None
            for row in users:
                uid_db, name, uid, tmpl_json = row
                score = match_templates(input_minutiae, json.loads(tmpl_json),
                                        algorithm=MATCHING_ALGORITHM)
                if score > best_score:
                    best_score = score; best_user = (uid_db, name, uid)

            if not best_user or best_score < SINGLE_THRESHOLD:
                return jsonify({"success": False, "message": "No match found",
                                "confidence": round(best_score, 4)})

            uid_db, name, uid = best_user
            c.execute("INSERT INTO authentications (user_id,timestamp,confidence,matched) VALUES (?,?,?,1)",
                      (uid_db, datetime.now().isoformat(), best_score))
            conn.commit()
        finally:
            conn.close()

        return jsonify({"success": True, "name": name, "uid": uid,
                        "confidence": round(best_score, 4)})
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/v2/verify", methods=["POST"])
def verify_v2():
    try:
        uid   = request.form.get("uid", "").strip()
        batch = request.form.get("batch", "").strip()
        if not uid or not batch:
            return jsonify({"success": False, "error": "uid and batch required"}), 400
        if "image" not in request.files:
            return jsonify({"success": False, "error": "image required"}), 400

        path = _save_upload()
        preprocessed = cv2.imread(path)
        if preprocessed is None:
            return jsonify({"success": False, "error": "image could not be decoded"}), 400

        input_minutiae = detect_minutiae(preprocessed)

        conn = get_connection()
        try:
            c = conn.cursor()
            c.execute("SELECT id,name,uid,template_json FROM users WHERE uid=? AND batch=?", (uid, batch))
            row = c.fetchone()
        finally:
            conn.close()
        if not row:
            return jsonify({"success": False, "error": f"No user found: {uid}"}), 404

        user_id, name, uid_db, tmpl_json = row
        score   = match_templates(input_minutiae, json.loads(tmpl_json),
                                  algorithm=MATCHING_ALGORITHM)
        matched = score >= SINGLE_THRESHOLD

        # Log every verify attempt (matched or not) so a history view can show them.
        log_conn = get_connection()
        try:
            log_conn.execute(
                "INSERT INTO authentications (user_id,timestamp,confidence,matched) VALUES (?,?,?,?)",
                (user_id, datetime.now().isoformat(), score, 1 if matched else 0)
            )
            log_conn.commit()
        finally:
            log_conn.close()

        return jsonify({
            "success":    True,
            "matched":    matched,
            "confidence": round(score, 4),
            "threshold":  SINGLE_THRESHOLD,
            "name":       name,
            "uid":        uid_db,
            "input_minutiae_count": len(input_minutiae),
        })
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


# ══════════════════════════════════════════════════════════════════════════════
# SLAP — /v2/enroll_slap, /v2/authenticate_slap, /v2/verify_slap
# Moved from slap_app.py; aggregation now goes through slap_matching's
# score_against_user() instead of two separately-duplicated formulas
# (see slap_matching.py's docstring, bug.md #8).
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/v2/enroll_slap", methods=["POST"])
def enroll_slap_v2():
    try:
        uid = request.form.get("uid", "").strip()
        if not uid:
            return jsonify({"success": False, "error": "uid required"}), 400
        name      = request.form.get("name", "")
        batch     = request.form.get("batch", "default")
        hand_side = request.form.get("hand_side", "right")

        imgs = _read_images_list()
        if not imgs:
            return jsonify({"success": False, "error": "at least one image required"}), 400
        labels = label_by_order(len(imgs), hand_side, _parse_finger_order())

        con = sqlite3.connect(SLAP_DB)
        now = datetime.utcnow().isoformat()
        saved = []
        for img, label in zip(imgs, labels):
            minutiae = detect_minutiae(img)
            con.execute(
                """INSERT OR REPLACE INTO slap_templates
                   (uid,name,batch,finger_position,iso_code,minutiae_count,
                    template_b64,minutiae_json,created_at)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (uid, name, batch, label["finger_position"], label["iso_code"],
                 len(minutiae), "",  # template_b64 (ISO 19794-2 FMR) — not built
                 json.dumps(minutiae), now),                                   # cloud-side yet; minutiae_json is
            )                                                                  # what matching actually reads.
            saved.append({
                "finger_position": label["finger_position"],
                "iso_code": label["iso_code"],
                "minutiae_count": len(minutiae),
            })
        con.commit()
        con.close()

        return jsonify({
            "success": True,
            "uid": uid, "name": name, "batch": batch, "hand_side": hand_side,
            "enrolled_fingers": saved, "finger_count": len(saved),
        })
    except Exception as e:
        traceback.print_exc()
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/v2/authenticate_slap", methods=["POST"])
def authenticate_slap_v2():
    try:
        batch = request.form.get("batch", "").strip()
        hand_side = request.form.get("hand_side", "right")
        if not batch:
            return jsonify({"success": False, "error": "batch required"}), 400

        imgs = _read_images_list()
        if not imgs:
            return jsonify({"success": False, "error": "at least one image required"}), 400
        labels = label_by_order(len(imgs), hand_side, _parse_finger_order())
        fingers = [{"finger_position": lbl["finger_position"],
                    "minutiae": detect_minutiae(img)}
                   for img, lbl in zip(imgs, labels)]

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
            for uid, user_rows in by_uid.items():
                agg_score, finger_scores = score_against_user(fingers, user_rows)
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
                     "[]", now),
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


@app.route("/v2/verify_slap", methods=["POST"])
def verify_slap_v2():
    try:
        uid = request.form.get("uid", "").strip()
        batch = request.form.get("batch", "").strip()
        hand_side = request.form.get("hand_side", "right")
        if not uid or not batch:
            return jsonify({"success": False,
                            "error": "uid and batch required"}), 400

        imgs = _read_images_list()
        if not imgs:
            return jsonify({"success": False, "error": "at least one image required"}), 400
        labels = label_by_order(len(imgs), hand_side, _parse_finger_order())
        fingers = [{"finger_position": lbl["finger_position"],
                    "minutiae": detect_minutiae(img)}
                   for img, lbl in zip(imgs, labels)]

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

            user_rows = [{"finger_position": r["finger_position"],
                         "minutiae_json": r["minutiae_json"]} for r in rows]
            score, matched_fingers = score_against_user(fingers, user_rows)
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


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

# Module-level, not inside __main__: gunicorn imports this module as "cloud_app:app"
# rather than executing it directly, so anything gated behind __main__ (as app.py's
# init_db() is) silently never runs under a production WSGI server. Both are
# idempotent (CREATE TABLE IF NOT EXISTS), so this is safe to call on every import.
init_db()
init_slap_db()

if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("  SITAA cloud service — templatization + matching only")
    print("=" * 60)
    print("  POST /v2/enroll             — single-finger enroll")
    print("  POST /v2/authenticate       — single-finger 1:N")
    print("  POST /v2/verify             — single-finger 1:1")
    print("  POST /v2/enroll_slap        — slap enroll")
    print("  POST /v2/authenticate_slap  — slap 1:N")
    print("  POST /v2/verify_slap        — slap 1:1")
    print("  GET  /health")
    print("=" * 60 + "\n")
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
