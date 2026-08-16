"""
Invariance tests for the minutiae matcher.

These run with no model weights, no database and no TensorFlow, so they can be used to
validate a matcher change before any fingerprint data has been collected.

The rotation test is the important one. The team's own analysis identified "no rotation
handling" as the reason genuine scores sat at 0.130-0.201 against a 0.25 threshold, i.e.
0% TAR. test_legacy_collapses_under_rotation pins that failure in place; the matching
test on the current path proves it is fixed.

A new algorithm branch (see MATCHING_ALGORITHMS.md) gets this whole suite for free by
registering in matching.py's _ALGORITHMS dict and adding its name to CANDIDATE_ALGORITHMS
below — plus whichever of ROTATION_INVARIANT_ALGORITHMS, SCALE_ROBUST_ALGORITHMS,
UNIFORM_SCALE_INVARIANT_ALGORITHMS and RECAPTURE_ROBUST_ALGORITHMS it actually earns.
Don't assume membership from what the algorithm is supposed to do — run it through the
suite and see. Two real algorithms in this bake-off pass plain rotation invariance but
fail the harder recapture-based tests, and two others pass single-outlier robustness
but fail uniform rescaling; none of that was obvious up front. No test bodies need to
change either way.
"""

import math
import os
import random
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from matching import match_templates  # noqa: E402


# ── Synthetic data ───────────────────────────────────────────────────────────

def make_template(n=40, width=200, height=250, seed=0):
    """A plausible minutiae set. Spatially spread, mixed types, random directions."""
    rng = random.Random(seed)
    return [{
        "x": rng.uniform(0, width),
        "y": rng.uniform(0, height),
        "direction": rng.uniform(0, 2 * math.pi),
        "type": "BIF" if rng.random() > 0.5 else "RIG",
    } for _ in range(n)]


def rotate(tmpl, degrees):
    """
    Rotate a template as a rigid body.

    Both the coordinates and each minutia's ridge direction must rotate. Rotating only
    the coordinates would not simulate a turned finger, it would simulate a scrambled
    one, and the test would prove nothing.
    """
    th = math.radians(degrees)
    c, s = math.cos(th), math.sin(th)
    return [{**m,
             "x": m["x"] * c - m["y"] * s,
             "y": m["x"] * s + m["y"] * c,
             "direction": (m["direction"] + th) % (2 * math.pi)} for m in tmpl]


def translate(tmpl, dx, dy):
    return [{**m, "x": m["x"] + dx, "y": m["y"] + dy} for m in tmpl]


def rescale(tmpl, k):
    return [{**m, "x": m["x"] * k, "y": m["y"] * k} for m in tmpl]


def jitter(tmpl, px=2.0, rad=0.05, seed=99):
    """Small perturbation, standing in for capture-to-capture variation."""
    rng = random.Random(seed)
    return [{**m,
             "x": m["x"] + rng.uniform(-px, px),
             "y": m["y"] + rng.uniform(-px, px),
             "direction": (m["direction"] + rng.uniform(-rad, rad)) % (2 * math.pi)}
            for m in tmpl]


ROTATIONS = [0, 5, 10, 15, 20, 30, 45]

# Every algorithm registered in matching.py's _ALGORITHMS dict. A new algorithm branch
# adds its own name here and every generic test below (baseline sanity, translation,
# discrimination) runs against it automatically — no test bodies need to change. These
# are properties every algorithm here is expected to have regardless of design; if a
# new one can't clear these, that's a real problem with it, not a scoping question.
CANDIDATE_ALGORITHMS = [
    "legacy", "modern", "hungarian_assignment", "mcc_cylinder", "delaunay",
    "ransac_alignment", "jiang_yau", "bozorth3_style", "networkx_graph",
    "ransac_similarity",
]

# Subset of CANDIDATE_ALGORITHMS that survives a plain rotation of an otherwise-
# unmodified template. "legacy" is deliberately excluded — it is documented
# (test_legacy_collapses_under_rotation) to fail this by design, so folding it into
# the generic rotation sweep would just duplicate that pinned failure under a
# different name. A new algorithm only belongs here if it's actually meant to survive
# rotation. Verified empirically for every algorithm below (not assumed from its own
# self-report) before being added.
ROTATION_INVARIANT_ALGORITHMS = [
    "modern", "hungarian_assignment", "mcc_cylinder", "delaunay",
    "ransac_alignment", "jiang_yau", "bozorth3_style", "networkx_graph",
    "ransac_similarity",
]

# Subset of CANDIDATE_ALGORITHMS whose scale normalisation is robust to a single
# spurious outlier minutia. "legacy" scales by bounding-box span, so one stray point at
# the edge of the frame rescales the whole template — a real, already-documented
# property (matching.py's module docstring, point 3), not a test artefact. Every other
# registered algorithm passed this empirically.
SCALE_ROBUST_ALGORITHMS = [
    "modern", "hungarian_assignment", "mcc_cylinder", "delaunay",
    "ransac_alignment", "jiang_yau", "bozorth3_style", "networkx_graph",
    "ransac_similarity",
]

# Subset of CANDIDATE_ALGORITHMS robust to a UNIFORM rescale of the whole template —
# a different property from SCALE_ROBUST_ALGORITHMS above (one spurious point vs. every
# point moving together). "mcc_cylinder" is excluded: its cylinder radius is derived
# from median nearest-neighbour spacing but doesn't fully compensate at 1.5x scale
# (measured: score drops to 0.78x baseline, below the 0.8x bar). "ransac_alignment" is
# excluded because its transform model is deliberately rotation+translation only, with
# no scale component — a uniformly rescaled duplicate genuinely can't align under a
# scale-less rigid transform. "ransac_similarity" (algorithm009) exists specifically to
# fix this in ransac_alignment's lineage — it pre-normalises both templates to a
# canonical spacing before the same RANSAC search runs, and passes here where its
# predecessor doesn't; see backend/algorithms/ransac_similarity.py's module docstring.
UNIFORM_SCALE_INVARIANT_ALGORITHMS = [
    "legacy", "modern", "hungarian_assignment", "delaunay",
    "jiang_yau", "bozorth3_style", "networkx_graph", "ransac_similarity",
]

# Subset of ROTATION_INVARIANT_ALGORITHMS that also survives the harder, more realistic
# combined scenario recapture() simulates: rotation together with DROPPED minutiae,
# SPURIOUS minutiae, and jitter all at once — not just a clean rotation of an otherwise
# identical template. "delaunay" and "networkx_graph" both pass plain rotation
# invariance but fail here: Delaunay because a single dropped or shifted minutia
# restructures several neighbouring triangles and loses their votes (a documented,
# literature-known weakness of pure triangulation matching under partial overlap), and
# the NetworkX candidate because its one-hop local-correspondence step doesn't
# propagate evidence the way relaxation labeling does, so it discriminates more weakly
# once minutiae start going missing. Both limitations were self-reported by the
# algorithms' own implementers and confirmed empirically here.
RECAPTURE_ROBUST_ALGORITHMS = [
    "modern", "hungarian_assignment", "mcc_cylinder",
    "ransac_alignment", "jiang_yau", "bozorth3_style", "ransac_similarity",
]

# Subset of ROTATION_INVARIANT_ALGORITHMS that discriminates genuine-vs-impostor under
# rotation + jitter alone — no dropped/spurious minutiae, a step down in difficulty
# from RECAPTURE_ROBUST_ALGORITHMS above. Membership genuinely differs from that list:
# "networkx_graph" passes this one (rotation + jitter alone doesn't trip its weakness)
# but fails the harder drop/spurious combination above — a real, measured distinction,
# not an oversight. "delaunay" fails both.
ROTATED_JITTER_DISCRIMINATES_ALGORITHMS = [
    "modern", "hungarian_assignment", "mcc_cylinder",
    "ransac_alignment", "jiang_yau", "bozorth3_style", "networkx_graph",
    "ransac_similarity",
]


# ── Baseline ─────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("algorithm", CANDIDATE_ALGORITHMS)
def test_identical_templates_score_high(algorithm):
    t = make_template(seed=1)
    assert match_templates(t, t, algorithm=algorithm) > 0.5


@pytest.mark.parametrize("algorithm", CANDIDATE_ALGORITHMS)
def test_empty_input_is_zero(algorithm):
    t = make_template(seed=1)
    assert match_templates([], t, algorithm=algorithm) == 0.0
    assert match_templates(t, [], algorithm=algorithm) == 0.0


@pytest.mark.parametrize("algorithm", CANDIDATE_ALGORITHMS)
def test_count_ratio_gate(algorithm):
    """Wildly different minutiae counts are rejected before any geometry runs."""
    big = make_template(n=40, seed=1)
    small = big[:10]
    assert match_templates(big, small, algorithm=algorithm) == 0.0


# ── The fix ──────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("algorithm", ROTATION_INVARIANT_ALGORITHMS)
@pytest.mark.parametrize("degrees", ROTATIONS)
def test_rotation_invariance(degrees, algorithm):
    """A rotated capture of the same finger must still match."""
    t = make_template(seed=2)
    baseline = match_templates(t, t, algorithm=algorithm)
    rotated = match_templates(t, rotate(t, degrees), algorithm=algorithm)
    assert rotated >= 0.8 * baseline, (
        "algorithm=%s: rotation by %d deg dropped the score from %.3f to %.3f"
        % (algorithm, degrees, baseline, rotated)
    )


def test_legacy_collapses_under_rotation():
    """
    Pins the original defect.

    Not a regression guard — it documents why the matcher scored 0% TAR, and it will
    start failing if someone reverts the current path to the old descriptor.
    """
    t = make_template(seed=2)
    baseline = match_templates(t, t, algorithm="legacy")
    rotated = match_templates(t, rotate(t, 30), algorithm="legacy")
    assert baseline > 0.3, "legacy should still match a template against itself"
    assert rotated < 0.5 * baseline, (
        "expected the legacy matcher to fail under rotation, got %.3f vs %.3f"
        % (rotated, baseline)
    )


def test_rotation_invariance_beats_legacy():
    """Direct before/after on identical data."""
    t = make_template(seed=3)
    rotated = rotate(t, 30)
    assert match_templates(t, rotated) > match_templates(t, rotated, algorithm="legacy")


# ── Other invariances (these should already have held) ───────────────────────

@pytest.mark.parametrize("algorithm", CANDIDATE_ALGORITHMS)
@pytest.mark.parametrize("dx,dy", [(50, 30), (-120, 75), (500, -400)])
def test_translation_invariance(dx, dy, algorithm):
    t = make_template(seed=4)
    assert match_templates(t, translate(t, dx, dy), algorithm=algorithm) == pytest.approx(
        match_templates(t, t, algorithm=algorithm), rel=0.02)


@pytest.mark.parametrize("algorithm", UNIFORM_SCALE_INVARIANT_ALGORITHMS)
@pytest.mark.parametrize("k", [0.85, 1.15, 1.5])
def test_scale_invariance(k, algorithm):
    t = make_template(seed=5)
    assert match_templates(t, rescale(t, k), algorithm=algorithm) >= \
        0.8 * match_templates(t, t, algorithm=algorithm)


@pytest.mark.parametrize("algorithm", SCALE_ROBUST_ALGORITHMS)
def test_single_outlier_does_not_wreck_the_score(algorithm):
    """
    The original scaled by bounding-box span, so one stray minutia at the edge of the
    frame rescaled the whole template and shifted every distance bin.
    """
    t = make_template(seed=6)
    with_outlier = t + [{"x": 5000.0, "y": 5000.0,
                         "direction": 0.0, "type": "RIG"}]
    assert match_templates(t, with_outlier, algorithm=algorithm) >= \
        0.7 * match_templates(t, t, algorithm=algorithm)


# ── Discrimination ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("algorithm", CANDIDATE_ALGORITHMS)
def test_genuine_scores_above_impostor(algorithm):
    """A matcher that accepts everyone would pass every test above but not this one."""
    genuine, impostor = [], []
    for s in range(12):
        base = make_template(seed=100 + s)
        genuine.append(match_templates(base, jitter(base, seed=200 + s), algorithm=algorithm))
        impostor.append(match_templates(base, make_template(seed=900 + s), algorithm=algorithm))

    mean_g = sum(genuine) / len(genuine)
    mean_i = sum(impostor) / len(impostor)
    assert mean_g > mean_i, "algorithm=%s: genuine %.3f vs impostor %.3f" % (algorithm, mean_g, mean_i)
    assert mean_g - mean_i > 0.05, (
        "algorithm=%s: separation too small to threshold: genuine %.3f, impostor %.3f"
        % (algorithm, mean_g, mean_i))


def recapture(t, drop=0.3, spurious=0.2, rotation=20, seed=0):
    """
    A second capture of the same finger, simulated honestly.

    Two captures never yield the same minutiae set: extraction misses some, invents
    others, and the finger sits at a different angle. Testing only against a jittered
    copy of the same set flatters the matcher and hides exactly the failure mode that
    matters in the field.
    """
    rng = random.Random(seed)
    kept = [m for m in t if rng.random() > drop]
    xs = [m["x"] for m in t]
    ys = [m["y"] for m in t]
    for _ in range(int(len(t) * spurious)):
        kept.append({
            "x": rng.uniform(min(xs), max(xs)),
            "y": rng.uniform(min(ys), max(ys)),
            "direction": rng.uniform(0, 2 * math.pi),
            "type": "BIF" if rng.random() > 0.5 else "RIG",
        })
    return rotate(jitter(kept, px=3.0, rad=0.10, seed=seed), rotation)


@pytest.mark.parametrize("algorithm", RECAPTURE_ROBUST_ALGORITHMS)
@pytest.mark.parametrize("drop", [0.2, 0.3, 0.4])
def test_separation_survives_partial_minutiae_overlap(drop, algorithm):
    """
    Genuine must still outscore impostor when up to 40% of minutiae go missing.

    recapture() bakes in a 20-degree rotation by default (an honest second-capture
    simulation) on top of the drop/spurious/jitter noise, so this is scoped to
    RECAPTURE_ROBUST_ALGORITHMS — the subset of rotation-invariant algorithms that
    also holds up once minutiae start going missing, which is a strictly harder bar
    than plain rotation invariance (see the list's docstring above: two algorithms
    here pass rotation cleanly but fail this).
    """
    genuine, impostor = [], []
    for s in range(10):
        base = make_template(seed=500 + s)
        genuine.append(match_templates(base, recapture(base, drop=drop, seed=600 + s),
                                       algorithm=algorithm))
        impostor.append(match_templates(
            base, recapture(make_template(seed=800 + s), drop=drop, seed=610 + s),
            algorithm=algorithm))

    mean_g = sum(genuine) / len(genuine)
    mean_i = sum(impostor) / len(impostor)
    assert mean_g - mean_i > 0.08, (
        "algorithm=%s drop=%.0f%%: genuine %.3f vs impostor %.3f — not separable"
        % (algorithm, drop * 100, mean_g, mean_i))


@pytest.mark.parametrize("algorithm", ROTATED_JITTER_DISCRIMINATES_ALGORITHMS)
def test_rotated_genuine_still_beats_impostor(algorithm):
    """The property that actually matters in the field: rotation must not cause a miss."""
    for s in range(6):
        base = make_template(seed=300 + s)
        rotated_genuine = match_templates(base, rotate(jitter(base, seed=400 + s), 25),
                                          algorithm=algorithm)
        impostor = match_templates(base, make_template(seed=700 + s), algorithm=algorithm)
        assert rotated_genuine > impostor, (
            "algorithm=%s seed %d: rotated genuine %.3f did not beat impostor %.3f"
            % (algorithm, s, rotated_genuine, impostor))
