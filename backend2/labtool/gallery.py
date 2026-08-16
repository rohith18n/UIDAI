"""
Local gallery store for the bench.

Deliberately separate from the backend's uidai.db. The server's /users endpoint does
not return template_json, so a ranked 1:N table can only be built from templates the
bench holds itself. Keeping it local also means testing never writes into the shared
GCP database unless you explicitly ask it to.

Lives at backend/lab_gallery.db, which the existing `backend/*.db` gitignore rule covers.
Captured photos land in backend/labtool/dataset/ — fingerprint images of real people,
ignored for the same reason.
"""

import hashlib
import io
import json
import sqlite3
from datetime import datetime
from pathlib import Path

from PIL import Image

BASE_DIR = Path(__file__).resolve().parent
BACKEND_DIR = BASE_DIR.parent
DB_PATH = BACKEND_DIR / "lab_gallery.db"
DATASET_DIR = BASE_DIR / "dataset"

THUMB_SIZE = 220


# ══════════════════════════════════════════════════════════════════════════════
# CONNECTION / SCHEMA
# ══════════════════════════════════════════════════════════════════════════════

def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    conn = connect()
    try:
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS subjects (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                uid        TEXT NOT NULL UNIQUE,
                notes      TEXT DEFAULT '',
                created_at TEXT NOT NULL
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS templates (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                subject_id      INTEGER NOT NULL,
                finger_position INTEGER NOT NULL DEFAULT 0,
                minutiae_json   TEXT NOT NULL,
                minutiae_count  INTEGER NOT NULL,
                image_path      TEXT,
                image_sha256    TEXT,
                thumb_png       BLOB,
                liveness_conf   REAL,
                det_conf        REAL,
                qc_json         TEXT,
                fir_meta_json   TEXT,
                created_at      TEXT NOT NULL,
                UNIQUE(subject_id, finger_position),
                FOREIGN KEY(subject_id) REFERENCES subjects(id) ON DELETE CASCADE
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS probes (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                ts           TEXT NOT NULL,
                true_uid     TEXT,
                top1_uid     TEXT,
                top1_name    TEXT,
                top1_score   REAL,
                top2_score   REAL,
                threshold    REAL,
                decision     TEXT,
                scores_json  TEXT,
                image_sha256 TEXT
            )
        """)
        conn.commit()
    finally:
        conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_thumb(image_bytes: bytes, size: int = THUMB_SIZE) -> bytes:
    """Small PNG for the gallery grid, so rendering never re-reads full-resolution photos."""
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img = img.convert("RGB")
        img.thumbnail((size, size))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()
    except Exception:
        return b""


def save_dataset_image(image_bytes: bytes, uid: str, finger_position: int,
                       filename: str) -> str:
    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    suffix = Path(filename).suffix.lower() or ".jpg"
    safe_uid = "".join(ch for ch in uid if ch.isalnum() or ch in "-_") or "subject"
    target = DATASET_DIR / f"{safe_uid}_f{finger_position}{suffix}"
    target.write_bytes(image_bytes)
    return str(target)


# ══════════════════════════════════════════════════════════════════════════════
# SUBJECTS
# ══════════════════════════════════════════════════════════════════════════════

def upsert_subject(name: str, uid: str, notes: str = "") -> int:
    conn = connect()
    try:
        c = conn.cursor()
        c.execute("""
            INSERT INTO subjects (name, uid, notes, created_at) VALUES (?,?,?,?)
            ON CONFLICT(uid) DO UPDATE SET name=excluded.name, notes=excluded.notes
        """, (name.strip(), uid.strip(), notes, datetime.now().isoformat(timespec="seconds")))
        conn.commit()
        # lastrowid is unreliable on the UPDATE branch, so read the id back.
        row = c.execute("SELECT id FROM subjects WHERE uid=?", (uid.strip(),)).fetchone()
        return int(row["id"])
    finally:
        conn.close()


def list_subjects() -> list:
    conn = connect()
    try:
        rows = conn.execute("SELECT * FROM subjects ORDER BY name").fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def delete_subject(subject_id: int) -> None:
    conn = connect()
    try:
        conn.execute("DELETE FROM templates WHERE subject_id=?", (subject_id,))
        conn.execute("DELETE FROM subjects WHERE id=?", (subject_id,))
        conn.commit()
    finally:
        conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# TEMPLATES
# ══════════════════════════════════════════════════════════════════════════════

def upsert_template(subject_id: int, finger_position: int, minutiae: list,
                    image_path: str = "", image_sha256: str = "", thumb_png: bytes = b"",
                    liveness_conf: float = 0.0, det_conf: float = 0.0,
                    qc: dict = None, fir_meta: dict = None) -> int:
    conn = connect()
    try:
        c = conn.cursor()
        c.execute("""
            INSERT INTO templates (subject_id, finger_position, minutiae_json, minutiae_count,
                                   image_path, image_sha256, thumb_png, liveness_conf, det_conf,
                                   qc_json, fir_meta_json, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(subject_id, finger_position) DO UPDATE SET
                minutiae_json=excluded.minutiae_json,
                minutiae_count=excluded.minutiae_count,
                image_path=excluded.image_path,
                image_sha256=excluded.image_sha256,
                thumb_png=excluded.thumb_png,
                liveness_conf=excluded.liveness_conf,
                det_conf=excluded.det_conf,
                qc_json=excluded.qc_json,
                fir_meta_json=excluded.fir_meta_json,
                created_at=excluded.created_at
        """, (subject_id, int(finger_position), json.dumps(minutiae), len(minutiae),
              image_path, image_sha256, thumb_png, float(liveness_conf), float(det_conf),
              json.dumps(qc or {}), json.dumps(fir_meta or {}),
              datetime.now().isoformat(timespec="seconds")))
        conn.commit()
        row = c.execute("SELECT id FROM templates WHERE subject_id=? AND finger_position=?",
                        (subject_id, int(finger_position))).fetchone()
        return int(row["id"])
    finally:
        conn.close()


def list_templates(uid: str = "") -> list:
    """Gallery entries with the subject joined in. `minutiae` is already deserialised."""
    conn = connect()
    try:
        sql = """
            SELECT t.*, s.name AS name, s.uid AS uid
            FROM templates t JOIN subjects s ON t.subject_id = s.id
        """
        params = ()
        if uid:
            sql += " WHERE s.uid = ?"
            params = (uid,)
        sql += " ORDER BY s.name, t.finger_position"
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()

    entries = []
    for r in rows:
        entry = dict(r)
        try:
            entry["minutiae"] = json.loads(entry.pop("minutiae_json") or "[]")
        except (ValueError, TypeError):
            entry["minutiae"] = []
        for key in ("qc_json", "fir_meta_json"):
            try:
                entry[key.replace("_json", "")] = json.loads(entry.pop(key) or "{}")
            except (ValueError, TypeError):
                entry[key.replace("_json", "")] = {}
        entries.append(entry)
    return entries


def delete_template(template_id: int) -> None:
    conn = connect()
    try:
        conn.execute("DELETE FROM templates WHERE id=?", (template_id,))
        conn.commit()
    finally:
        conn.close()


def find_template_by_sha(image_sha256: str):
    """Used to catch the enrol-then-probe-the-same-file mistake before it looks like a result."""
    if not image_sha256:
        return None
    conn = connect()
    try:
        row = conn.execute("""
            SELECT t.id, t.finger_position, s.name, s.uid
            FROM templates t JOIN subjects s ON t.subject_id = s.id
            WHERE t.image_sha256 = ?
        """, (image_sha256,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# PROBES — every identification attempt, so genuine scores accumulate over time
# ══════════════════════════════════════════════════════════════════════════════

def log_probe(top1_uid: str, top1_name: str, top1_score: float, top2_score: float,
              threshold: float, decision: str, scores: list,
              true_uid: str = "", image_sha256: str = "") -> int:
    conn = connect()
    try:
        c = conn.cursor()
        c.execute("""
            INSERT INTO probes (ts, true_uid, top1_uid, top1_name, top1_score, top2_score,
                                threshold, decision, scores_json, image_sha256)
            VALUES (?,?,?,?,?,?,?,?,?,?)
        """, (datetime.now().isoformat(timespec="seconds"), true_uid or None,
              top1_uid, top1_name, float(top1_score), float(top2_score),
              float(threshold), decision,
              json.dumps([{"uid": s["uid"], "name": s["name"], "score": s["score"]}
                          for s in scores]),
              image_sha256))
        conn.commit()
        return int(c.lastrowid)
    finally:
        conn.close()


def set_probe_truth(probe_id: int, true_uid: str) -> None:
    conn = connect()
    try:
        conn.execute("UPDATE probes SET true_uid=? WHERE id=?", (true_uid or None, probe_id))
        conn.commit()
    finally:
        conn.close()


def list_probes() -> list:
    conn = connect()
    try:
        rows = conn.execute("SELECT * FROM probes ORDER BY id DESC").fetchall()
    finally:
        conn.close()

    probes = []
    for r in rows:
        p = dict(r)
        try:
            p["scores"] = json.loads(p.pop("scores_json") or "[]")
        except (ValueError, TypeError):
            p["scores"] = []
        probes.append(p)
    return probes


def clear_probes() -> None:
    conn = connect()
    try:
        conn.execute("DELETE FROM probes")
        conn.commit()
    finally:
        conn.close()
