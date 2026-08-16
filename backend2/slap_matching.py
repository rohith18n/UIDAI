"""
slap_matching.py — slap-specific matching orchestration.

matching.py's match_templates() compares two single-finger minutiae sets and has
no notion of "slap" at all. Everything in this file is the layer on top of it
that's specific to a capture having up to four fingers: position-constrained
per-finger matching, then aggregating those into one score per candidate.

Shared by cloud_app.py (the real cloud deployment) and slap_app.py (the
on-device-tier reference server) so this logic — including the position-
constrained fix from bug.md #2 — lives in exactly one place. matching.py's own
history is the cautionary tale for why: it used to exist as three diverging
copies before being consolidated into one module.

Consolidation note (bug.md #8): slap_app.py's authenticate_slap and verify_slap
used two DIFFERENT aggregation formulas — authenticate averaged only the fingers
that actually matched something (ignoring zero-scores), verify averaged ALL probe
fingers including zero-scores, which silently diluted a genuine match whenever any
finger didn't match. score_against_user() below standardizes on authenticate's
version (ignore non-matching fingers) since it's the less surprising of the two —
a finger the system couldn't compare shouldn't be scored as a hard zero against
the user. This makes verify's behavior slightly more lenient than it was before;
disclosed here and in bug.md rather than carried forward silently.
"""

import json

from matching import match_templates

MATCH_THRESH = 0.20
MATCHING_ALGORITHM = "legacy"

# ISO 19794-2 finger position codes.
ISO_FINGER_CODES = {
    "right_thumb": 1, "right_index": 2, "right_middle": 3, "right_ring": 4, "right_little": 5,
    "left_thumb": 6, "left_index": 7, "left_middle": 8, "left_ring": 9, "left_little": 10,
}

# A 4-finger slap (no thumb), labelled by LEFT->RIGHT image order. Override per
# request with finger_order (comma-separated) if capture geometry differs.
SLAP_ORDER = {
    "right": ["right_little", "right_ring", "right_middle", "right_index"],
    "left":  ["left_index", "left_middle", "left_ring", "left_little"],
}


def label_by_order(n, hand_side, finger_order=None):
    """Assign finger_position/iso_code by upload order — the on-device app has
    already detected and ordered the fingers; the cloud side just trusts the
    declared hand_side/finger_order, the same way label_fingers() assigns
    positions to detected boxes in the on-device-tier reference server."""
    order = finger_order or SLAP_ORDER.get(hand_side, [])
    labels = []
    for idx in range(n):
        pos = order[idx] if idx < len(order) else f"{hand_side}_finger_{idx + 1}"
        labels.append({"finger_position": pos, "iso_code": ISO_FINGER_CODES.get(pos)})
    return labels


def best_finger_match(probe_min, user_rows, probe_position=None):
    """Match one probe minutiae set against a user's enrolled finger(s); return
    (best_score, matched_position, all_scores_per_pos).

    When probe_position is given, only compares against the stored template at
    that SAME position — a probe finger's declared identity shouldn't be free to
    search every stored position for a lucky match (bug.md #2). Without a
    position, unconstrained — searches every stored finger for this user."""
    best_score = 0.0
    matched_pos = None
    per_pos = {}
    for user_row in user_rows:
        pos = user_row["finger_position"]
        if probe_position is not None and pos != probe_position:
            continue
        try:
            stored_min = json.loads(user_row["minutiae_json"])
        except Exception:
            continue
        if not stored_min:
            continue
        s = match_templates(probe_min, stored_min, algorithm=MATCHING_ALGORITHM)
        per_pos[pos] = round(s, 5)
        if s > best_score:
            best_score = s
            matched_pos = pos
    return best_score, matched_pos, per_pos


def score_against_user(probe_fingers, user_rows):
    """
    Aggregate score for one candidate user against a set of probe fingers.

    probe_fingers: list of {"finger_position": str, "minutiae": list}
    user_rows:     list of {"finger_position": str, "minutiae_json": str}

    Returns (agg_score, matched_fingers) — matched_fingers is the per-finger
    detail list (probe_position, matched_position, confidence) for whichever
    probe fingers found a same-position stored counterpart. agg_score is the
    average of the top 2 scores among fingers that actually matched something;
    0.0 if none did. A finger with no stored counterpart at its position simply
    doesn't contribute — it is not scored as a zero that dilutes the average.
    """
    matched_fingers = []
    nonzero_scores = []
    for f in probe_fingers:
        s, mpos, _ = best_finger_match(f["minutiae"], user_rows,
                                        probe_position=f["finger_position"])
        if s > 0.0:
            matched_fingers.append({
                "probe_position": f["finger_position"],
                "matched_position": mpos,
                "confidence": round(s, 5),
            })
            nonzero_scores.append(s)

    if not nonzero_scores:
        return 0.0, matched_fingers

    top = sorted(nonzero_scores, reverse=True)[:2]
    agg_score = sum(top) / len(top)
    return agg_score, matched_fingers
