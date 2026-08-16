"""
Local ranking and calibration.

Scoring goes through `matching.match_templates` — the same matcher app.py, slap_app.py
and benchmark.py use. Nothing here reimplements it; the point of ranking locally is to
see every candidate's score, which /authenticate does not return.

The FAR/FRR sweep mirrors benchmark.py:419 — sort each score list once, then use
bisect_left per threshold instead of rescoring.
"""

import itertools
import sys
from bisect import bisect_left
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from matching import match_templates, list_algorithms, algorithm_display_name, ALGORITHM_INFO  # noqa: E402

DEFAULT_THRESHOLD = 0.25  # what app.py:1484 and slap_app.py hardcode today
DEFAULT_ALGORITHM = "modern"


# ══════════════════════════════════════════════════════════════════════════════
# 1:N IDENTIFICATION
# ══════════════════════════════════════════════════════════════════════════════

def identify(probe_minutiae: list, entries: list, algorithm: str = DEFAULT_ALGORITHM) -> list:
    """
    Score a probe against every gallery entry, best first.

    `entries` are rows from gallery.list_templates(). Returns one dict per entry with
    the score attached, so the UI can show the whole candidate list and the rank-1
    margin rather than just the winner. `algorithm` selects which matching.py scorer
    runs — see matching.list_algorithms() for the registered names.
    """
    ranked = []
    for entry in entries:
        gallery_minutiae = entry.get("minutiae") or []
        score = float(match_templates(probe_minutiae, gallery_minutiae, algorithm=algorithm))
        ranked.append({
            "template_id": entry.get("id"),
            "uid": entry.get("uid", ""),
            "name": entry.get("name", ""),
            "finger_position": entry.get("finger_position", 0),
            "minutiae_count": entry.get("minutiae_count", len(gallery_minutiae)),
            "score": score,
            "entry": entry,
        })
    ranked.sort(key=lambda r: r["score"], reverse=True)
    return ranked


def decide(ranked: list, threshold: float) -> dict:
    """Turn a ranked list into an accept/reject with the numbers the demo needs to show."""
    if not ranked:
        return {"decision": "no_gallery", "top1": None, "top1_score": 0.0,
                "top2_score": 0.0, "margin": 0.0}

    top1 = ranked[0]
    top2_score = ranked[1]["score"] if len(ranked) > 1 else 0.0
    return {
        "decision": "match" if top1["score"] >= threshold else "no_match",
        "top1": top1,
        "top1_score": top1["score"],
        "top2_score": top2_score,
        "margin": top1["score"] - top2_score,
    }


# ══════════════════════════════════════════════════════════════════════════════
# PAIR SCORING — genuine vs impostor
# ══════════════════════════════════════════════════════════════════════════════

def gallery_pairs(entries: list, algorithm: str = DEFAULT_ALGORITHM) -> dict:
    """
    Score every gallery pair once, split by whether the two entries are the same person.

    With one photo per person the genuine list comes back empty — that is expected, and
    the caller should say so rather than plot nothing. Impostor scores alone still give
    a defensible lower bound for the decision threshold.
    """
    genuine, impostor = [], []
    for a, b in itertools.combinations(entries, 2):
        score = float(match_templates(a.get("minutiae") or [],
                                      b.get("minutiae") or [], algorithm=algorithm))
        row = {
            "a_name": a.get("name", ""), "a_uid": a.get("uid", ""),
            "b_name": b.get("name", ""), "b_uid": b.get("uid", ""),
            "score": score,
        }
        if a.get("uid") == b.get("uid"):
            row["kind"] = "genuine"
            genuine.append(row)
        else:
            row["kind"] = "impostor"
            impostor.append(row)
    return {"genuine": genuine, "impostor": impostor}


# ══════════════════════════════════════════════════════════════════════════════
# CROSS-ALGORITHM COMPARISON — the actual bake-off. Minutiae extraction (the slow,
# network-bound part) happens once; scoring against every registered algorithm is
# local numpy/scipy work, cheap enough to always do all of them rather than one at a
# time. See MATCHING_ALGORITHMS.md for what each registered name is.
# ══════════════════════════════════════════════════════════════════════════════

def identify_all_algorithms(probe_minutiae: list, entries: list, threshold: float) -> list:
    """
    Run identify()+decide() once per registered algorithm against the same probe and
    gallery scope. One row per algorithm — the comparison view for a single capture.
    """
    rows = []
    for algo in list_algorithms():
        ranked = identify(probe_minutiae, entries, algorithm=algo) if probe_minutiae else []
        verdict = decide(ranked, threshold)
        info = ALGORITHM_INFO.get(algo, {})
        rows.append({
            "algorithm": algo,
            "code": info.get("code", ""),
            "label": info.get("label", algo),
            "display": algorithm_display_name(algo),
            "top1_name": verdict["top1"]["name"] if verdict["top1"] else "",
            "top1_uid": verdict["top1"]["uid"] if verdict["top1"] else "",
            "top1_score": verdict["top1_score"],
            "top2_score": verdict["top2_score"],
            "margin": verdict["margin"],
            "decision": verdict["decision"],
        })
    rows.sort(key=lambda r: r["code"])
    return rows


def gallery_pairs_all_algorithms(entries: list) -> list:
    """
    Score every gallery pair under every registered algorithm — the live version of
    MATCHING_ALGORITHMS.md's results table, computed against whatever gallery is
    actually enrolled right now instead of synthetic data.
    """
    rows = []
    for algo in list_algorithms():
        pairs = gallery_pairs(entries, algorithm=algo)
        impostor = [p["score"] for p in pairs["impostor"]]
        genuine = [p["score"] for p in pairs["genuine"]]
        info = ALGORITHM_INFO.get(algo, {})
        rows.append({
            "algorithm": algo,
            "code": info.get("code", ""),
            "label": info.get("label", algo),
            "display": algorithm_display_name(algo),
            "impostor_count": len(impostor),
            "impostor_mean": (sum(impostor) / len(impostor)) if impostor else None,
            "impostor_max": max(impostor) if impostor else None,
            "genuine_count": len(genuine),
            "genuine_mean": (sum(genuine) / len(genuine)) if genuine else None,
            "separation": ((sum(genuine) / len(genuine)) - (sum(impostor) / len(impostor)))
                          if genuine and impostor else None,
        })
    rows.sort(key=lambda r: r["code"])
    return rows


def genuine_scores_from_probes(probes: list) -> list:
    """
    Genuine scores harvested from labelled identification attempts.

    A probe you have tagged with a true identity contributes that subject's score from
    the run — which is the only source of genuine data when the gallery holds a single
    photo per person.
    """
    scores = []
    for probe in probes:
        true_uid = probe.get("true_uid")
        if not true_uid:
            continue
        for row in probe.get("scores", []):
            if row.get("uid") == true_uid:
                scores.append({"uid": true_uid, "name": row.get("name", ""),
                               "score": float(row.get("score", 0.0)),
                               "ts": probe.get("ts", "")})
                break
    return scores


def impostor_scores_from_probes(probes: list) -> list:
    """Non-matching candidates from labelled probes — real impostor comparisons, not gallery pairs."""
    scores = []
    for probe in probes:
        true_uid = probe.get("true_uid")
        if not true_uid:
            continue
        for row in probe.get("scores", []):
            if row.get("uid") != true_uid:
                scores.append({"uid": row.get("uid", ""), "name": row.get("name", ""),
                               "score": float(row.get("score", 0.0)),
                               "ts": probe.get("ts", "")})
    return scores


# ══════════════════════════════════════════════════════════════════════════════
# THRESHOLD SWEEP
# ══════════════════════════════════════════════════════════════════════════════

def sweep(genuine: list, impostor: list, step: float = 0.01) -> dict:
    """
    FAR/FRR across the threshold range, plus the EER row.

    genuine/impostor are plain float lists. Returns rows of
    {threshold, far, frr, tar, false_accepts, false_rejects} and, when both sides have
    data, the equal-error row and a recommended operating threshold.
    """
    g = sorted(float(s) for s in genuine)
    i = sorted(float(s) for s in impostor)
    n_g, n_i = len(g), len(i)

    rows = []
    t = 0.0
    while t <= 1.0 + 1e-9:
        thr = round(t, 4)
        false_accepts = n_i - bisect_left(i, thr) if n_i else 0
        false_rejects = bisect_left(g, thr) if n_g else 0
        far = (false_accepts / n_i) if n_i else None
        frr = (false_rejects / n_g) if n_g else None
        rows.append({
            "threshold": thr,
            "far": far,
            "frr": frr,
            "tar": (1.0 - frr) if frr is not None else None,
            "false_accepts": false_accepts,
            "false_rejects": false_rejects,
        })
        t += step

    result = {"rows": rows, "genuine_count": n_g, "impostor_count": n_i,
              "eer": None, "eer_threshold": None, "recommended": None,
              "basis": "none"}

    if n_g and n_i:
        eer_row = min(rows, key=lambda r: abs(r["far"] - r["frr"]))
        result["eer"] = (eer_row["far"] + eer_row["frr"]) / 2.0
        result["eer_threshold"] = eer_row["threshold"]
        result["recommended"] = eer_row["threshold"]
        result["basis"] = "eer"
    elif n_i:
        # No genuine data yet. The most defensible thing available is a threshold that
        # sits clear of every impostor score seen so far — a FAR=0 floor, not a
        # calibrated operating point. Labelled probes replace this with a real EER.
        result["recommended"] = round(min(1.0, max(i) + 0.05), 3)
        result["basis"] = "impostor_floor"

    return result


def rank1_accuracy(probes: list, threshold: float) -> dict:
    """
    User-wise rank-1 accuracy over labelled probes — the >85% acceptance gate.

    A probe counts as correct when rank 1 is the true subject *and* the score clears the
    threshold. Per-subject rates are reported because the gate is user-wise, not overall.
    """
    per_subject = {}
    total = correct = 0
    for probe in probes:
        true_uid = probe.get("true_uid")
        if not true_uid:
            continue
        scores = sorted(probe.get("scores", []), key=lambda s: s.get("score", 0.0), reverse=True)
        if not scores:
            continue
        top = scores[0]
        hit = top.get("uid") == true_uid and float(top.get("score", 0.0)) >= threshold
        bucket = per_subject.setdefault(true_uid, {"uid": true_uid, "attempts": 0, "correct": 0,
                                                   "name": ""})
        bucket["attempts"] += 1
        bucket["correct"] += int(hit)
        for row in probe.get("scores", []):
            if row.get("uid") == true_uid:
                bucket["name"] = row.get("name", "")
                break
        total += 1
        correct += int(hit)

    for bucket in per_subject.values():
        bucket["accuracy"] = bucket["correct"] / bucket["attempts"] if bucket["attempts"] else 0.0

    return {
        "overall": (correct / total) if total else None,
        "attempts": total,
        "correct": correct,
        "per_subject": sorted(per_subject.values(), key=lambda b: b["name"] or b["uid"]),
    }
