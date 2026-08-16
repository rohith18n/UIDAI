import argparse
import csv
import heapq
import json
import logging
import math
import os
import random
import sqlite3
import tempfile
from bisect import bisect_left
from dataclasses import dataclass
from itertools import combinations

os.environ.setdefault("MPLCONFIGDIR", os.path.join(tempfile.gettempdir(), "matplotlib"))

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    plt = None


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATABASE = os.path.join(BASE_DIR, "uidai.db")
CSV_PATH = os.path.join(BASE_DIR, "benchmark_results.csv")
PLOT_PATH = os.path.join(BASE_DIR, "eer_plot.png")

THRESHOLDS = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
EXACT_PAIR_LIMIT = 50000
DEFAULT_MAX_GENUINE_PAIRS = 50000
DEFAULT_MAX_IMPOSTOR_PAIRS = 50000
PAIR_SAMPLE_FLOOR = 5000
PAIR_SAMPLE_SCALE = 4000.0
RANDOM_SEED = 42

K_NEIGHBORS = 6
DIST_BIN_SIZE = 15
ANGLE_BINS = 16
ORIENT_BINS = 16
DIST_THRESH = 1
ANGLE_THRESH = 1
ORIENT_THRESH = 1
RELAX_ITER = 10


@dataclass(frozen=True)
class BenchmarkConfig:
    max_genuine_pairs: int = DEFAULT_MAX_GENUINE_PAIRS
    max_impostor_pairs: int = DEFAULT_MAX_IMPOSTOR_PAIRS
    seed: int = RANDOM_SEED
    algorithm: str = "modern"


from matching import match_templates as shared_match
from matching import list_algorithms as shared_algorithms

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("benchmark")


def angle_to_bin(theta, bins):
    return int((theta % (2 * math.pi)) / (2 * math.pi) * bins)


def circ_diff(a, b, bins):
    diff = abs(a - b)
    return min(diff, bins - diff)


def squared_distance(p1, p2):
    dx = p1["x"] - p2["x"]
    dy = p1["y"] - p2["y"]
    return dx * dx + dy * dy


def compute_edge(p1, p2):
    dx = p2["x"] - p1["x"]
    dy = p2["y"] - p1["y"]
    dist = math.sqrt(dx * dx + dy * dy)
    return (
        int(dist / DIST_BIN_SIZE),
        angle_to_bin(math.atan2(dy, dx), ANGLE_BINS),
        (
            angle_to_bin(p2["direction"], ORIENT_BINS)
            - angle_to_bin(p1["direction"], ORIENT_BINS)
        ) % ORIENT_BINS,
    )


def build_graph(template):
    edges = {}
    node_neighbors = [[] for _ in template]
    for i in range(len(template)):
        nearest = heapq.nsmallest(
            K_NEIGHBORS,
            (
                (squared_distance(template[i], template[j]), j)
                for j in range(len(template))
                if j != i
            ),
        )
        for _, j in nearest:
            edges[(i, j)] = compute_edge(template[i], template[j])
            node_neighbors[i].append(j)
    return edges, node_neighbors


def edge_compatible(e1, e2):
    d1, a1, o1 = e1
    d2, a2, o2 = e2
    if abs(d1 - d2) > DIST_THRESH:
        return 0.0
    if circ_diff(a1, a2, ANGLE_BINS) > ANGLE_THRESH:
        return 0.0
    if circ_diff(o1, o2, ORIENT_BINS) > ORIENT_THRESH:
        return 0.0
    return math.exp(
        -(
            abs(d1 - d2)
            + circ_diff(a1, a2, ANGLE_BINS)
            + circ_diff(o1, o2, ORIENT_BINS)
        )
    )


def normalize_template(template):
    if not template:
        return []
    mean_x = sum(point["x"] for point in template) / len(template)
    mean_y = sum(point["y"] for point in template) / len(template)
    return [{**point, "x": point["x"] - mean_x, "y": point["y"] - mean_y} for point in template]


def scale_template(template, target=200):
    if not template:
        return []
    xs = [point["x"] for point in template]
    ys = [point["y"] for point in template]
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1)
    factor = target / span
    return [{**point, "x": point["x"] * factor, "y": point["y"] * factor} for point in template]


def prepare_template(template):
    """
    Wrap a raw template for the pair lookup.

    Normalisation, scaling and graph construction used to happen here and be cached.
    They now live inside matching.match_templates, so that this benchmark measures
    exactly the matcher that runs in production rather than a second implementation
    of it that could drift.
    """
    return {"template": template, "size": len(template)}


def pair_count(size):
    return size * (size - 1) // 2


def choose_sample_size(total_pairs, max_pairs):
    if total_pairs <= max_pairs:
        return total_pairs
    scaled = int(math.log10(total_pairs + 1) * PAIR_SAMPLE_SCALE)
    return min(max_pairs, max(PAIR_SAMPLE_FLOOR, scaled))


def sample_weighted_index(weights, total_weight, rng):
    pick = rng.randrange(total_weight)
    return bisect_left(weights, pick + 1)


def build_candidate_links(left, right):
    t1 = left["template"]
    t2 = right["template"]
    if not t1 or not t2:
        return [], []

    right_bins = {}
    for j, node in enumerate(t2):
        key = (node["type"], node["direction_bin"])
        right_bins.setdefault(key, []).append(j)

    candidates = []
    candidate_index = {}
    for i, node in enumerate(t1):
        left_bin = node["direction_bin"]
        for offset in (-1, 0, 1):
            key = (node["type"], (left_bin + offset) % ORIENT_BINS)
            for j in right_bins.get(key, ()):
                other = t2[j]
                if abs(node["x"] - other["x"]) > 25:
                    continue
                if abs(node["y"] - other["y"]) > 25:
                    continue
                pair = (i, j)
                candidate_index[pair] = len(candidates)
                candidates.append(pair)

    links = [[] for _ in candidates]
    if not candidates:
        return candidates, links

    left_edges = left["graph"]
    right_edges = right["graph"]
    left_neighbors = left["neighbors"]
    right_neighbors = right["neighbors"]

    for idx, (i, j) in enumerate(candidates):
        src_links = links[idx]
        for k in left_neighbors[i]:
            left_edge = left_edges.get((i, k))
            if left_edge is None:
                continue
            for l in right_neighbors[j]:
                neighbor_idx = candidate_index.get((k, l))
                if neighbor_idx is None:
                    continue
                weight = edge_compatible(left_edge, right_edges.get((j, l)))
                if weight:
                    src_links.append((neighbor_idx, weight))

    return candidates, links


def sample_genuine_pairs(grouped, target_count, rng):
    groups = []
    weights = []
    for records in grouped.values():
        if len(records) < 2:
            continue
        groups.append(records)
        weights.append(pair_count(len(records)))

    total_pairs = sum(weights)
    if total_pairs == 0:
        return [], 0

    if total_pairs <= target_count:
        pairs = []
        for records in groups:
            for left, right in combinations(records, 2):
                pairs.append((left["id"], right["id"]))
        return pairs, total_pairs

    cumulative = []
    running = 0
    for weight in weights:
        running += weight
        cumulative.append(running)

    sampled = []
    seen = set()
    attempts = 0
    max_attempts = target_count * 20

    while len(sampled) < target_count and attempts < max_attempts:
        group_index = sample_weighted_index(cumulative, total_pairs, rng)
        records = groups[group_index]
        left, right = rng.sample(records, 2)
        pair = tuple(sorted((left["id"], right["id"])))
        attempts += 1
        if pair in seen:
            continue
        seen.add(pair)
        sampled.append(pair)

    return sampled, total_pairs


def sample_impostor_pairs(users, grouped, target_count, total_pairs, rng):
    if total_pairs == 0:
        return []

    if total_pairs <= target_count:
        pairs = []
        groups = [records for records in grouped.values() if records]
        for left_group, right_group in combinations(groups, 2):
            for left in left_group:
                for right in right_group:
                    pairs.append((left["id"], right["id"]))
        return pairs

    sampled = []
    seen = set()
    attempts = 0
    max_attempts = target_count * 25

    while len(sampled) < target_count and attempts < max_attempts:
        left, right = rng.sample(users, 2)
        attempts += 1
        if left["uid"] == right["uid"]:
            continue
        pair = tuple(sorted((left["id"], right["id"])))
        if pair in seen:
            continue
        seen.add(pair)
        sampled.append(pair)

    return sampled


def match_templates(left, right, algorithm="modern"):
    """Delegates to the shared matcher so benchmark numbers reflect production."""
    return shared_match(left["template"], right["template"], algorithm=algorithm)


def parse_template(raw):
    try:
        data = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return None

    if not isinstance(data, list):
        return None

    cleaned = []
    for point in data:
        if not isinstance(point, dict):
            continue
        try:
            minutia = {
                "x": float(point["x"]),
                "y": float(point["y"]),
                "direction": float(point["direction"]),
                "type": str(point["type"]).upper(),
            }
        except (KeyError, TypeError, ValueError):
            continue
        if minutia["type"] not in {"BIF", "RIG"}:
            continue
        cleaned.append(minutia)

    return cleaned or None


def load_users():
    """Load all valid templates from the SQLite database."""
    if not os.path.exists(DATABASE):
        raise FileNotFoundError(f"Database not found: {DATABASE}")
    if os.path.getsize(DATABASE) == 0:
        raise RuntimeError("uidai.db exists but is empty")

    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    try:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "users" not in tables:
            raise RuntimeError("`users` table not found in uidai.db")

        rows = conn.execute(
            """
            SELECT id, uid, template_json
            FROM users
            ORDER BY uid, id
            """
        ).fetchall()
    finally:
        conn.close()

    users = []
    for row in rows:
        template = parse_template(row["template_json"])
        if template is None:
            continue
        users.append(
            {
                "id": row["id"],
                "uid": row["uid"] or "",
                "prepared": prepare_template(template),
            }
        )
    return users


def build_pairs(users, max_genuine_pairs, max_impostor_pairs, seed):
    """Build the pair lists used by the benchmark."""
    grouped = {}
    for user in users:
        grouped.setdefault(user["uid"], []).append(user)

    rng = random.Random(seed)

    total_genuine_pairs = sum(pair_count(len(records)) for records in grouped.values())
    total_users = len(users)
    total_impostor_pairs = pair_count(total_users) - total_genuine_pairs

    genuine_exhaustive = total_genuine_pairs <= EXACT_PAIR_LIMIT
    impostor_exhaustive = total_impostor_pairs <= EXACT_PAIR_LIMIT
    genuine_target = total_genuine_pairs if genuine_exhaustive else choose_sample_size(total_genuine_pairs, max_genuine_pairs)
    impostor_target = total_impostor_pairs if impostor_exhaustive else choose_sample_size(total_impostor_pairs, max_impostor_pairs)

    genuine_pairs, total_genuine_pairs = sample_genuine_pairs(
        grouped,
        genuine_target,
        rng,
    )

    impostor_pairs = sample_impostor_pairs(
        users,
        grouped,
        impostor_target,
        total_impostor_pairs,
        rng,
    )

    mode = ", ".join(
        [
            f"genuine={'exhaustive' if genuine_exhaustive else 'sampled'}",
            f"impostor={'exhaustive' if impostor_exhaustive else 'sampled'}",
        ]
    )
    return genuine_pairs, impostor_pairs, total_impostor_pairs, total_genuine_pairs, mode


def score_pairs(pairs, prepared_lookup, algorithm="modern"):
    return [match_templates(prepared_lookup[left_id], prepared_lookup[right_id], algorithm=algorithm)
            for left_id, right_id in pairs]


def compute_metrics(genuine_scores, impostor_scores):
    """Turn raw scores into FAR/FRR rows and the approximate EER point."""
    genuine_scores = sorted(float(score) for score in genuine_scores)
    impostor_scores = sorted(float(score) for score in impostor_scores)
    genuine_count = len(genuine_scores)
    impostor_count = len(impostor_scores)

    rows = []
    for threshold in THRESHOLDS:
        false_accepts = impostor_count - bisect_left(impostor_scores, threshold) if impostor_count else 0
        false_rejects = bisect_left(genuine_scores, threshold) if genuine_count else 0

        far = false_accepts / impostor_count if impostor_count else float("nan")
        frr = false_rejects / genuine_count if genuine_count else float("nan")
        rows.append(
            {
                "threshold": threshold,
                "far": far,
                "frr": frr,
                "false_accepts": false_accepts,
                "false_rejects": false_rejects,
                "total_genuine_pairs": genuine_count,
                "total_impostor_pairs": impostor_count,
            }
        )

    eer_row = None
    valid_rows = [row for row in rows if not math.isnan(row["far"]) and not math.isnan(row["frr"])]
    if valid_rows:
        eer_row = min(valid_rows, key=lambda row: abs(row["far"] - row["frr"]))
        eer_row = {**eer_row, "eer": (eer_row["far"] + eer_row["frr"]) / 2.0}

    return rows, eer_row


def write_csv(rows, eer_row):
    """Write threshold metrics to CSV."""
    with open(CSV_PATH, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "threshold",
                "far",
                "frr",
                "false_accepts",
                "false_rejects",
                "total_genuine_pairs",
                "total_impostor_pairs",
                "eer_threshold",
                "eer",
            ],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    **row,
                    "eer_threshold": eer_row["threshold"] if eer_row else "",
                    "eer": eer_row["eer"] if eer_row else "",
                }
            )


def write_plot(rows, eer_row, message=None):
    """Write the FAR/FRR plot if matplotlib is available."""
    if plt is None:
        return

    plt.figure(figsize=(8, 5))
    if rows:
        thresholds = [row["threshold"] for row in rows]
        fars = [row["far"] for row in rows]
        frrs = [row["frr"] for row in rows]
        plt.plot(thresholds, fars, marker="o", label="FAR")
        plt.plot(thresholds, frrs, marker="s", label="FRR")
        if eer_row:
            plt.scatter(
                [eer_row["threshold"]],
                [eer_row["eer"]],
                color="red",
                zorder=3,
                label=f"EER ~ {eer_row['eer']:.4f}",
            )
            plt.axvline(eer_row["threshold"], color="red", linestyle="--", alpha=0.4)
        plt.legend()
    else:
        plt.text(
            0.5,
            0.5,
            message or "No benchmark data available.",
            ha="center",
            va="center",
            transform=plt.gca().transAxes,
            wrap=True,
        )

    plt.title("Fingerprint Matching Benchmark")
    plt.xlabel("Threshold")
    plt.ylabel("Rate")
    plt.ylim(0, 1)
    plt.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(PLOT_PATH, dpi=160)
    plt.close()


def write_error_csv(message):
    """Persist a one-line error CSV when the benchmark fails early."""
    with open(CSV_PATH, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["error"])
        writer.writerow([message])


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run a FAR/FRR fingerprint benchmark over the users table in uidai.db."
    )
    parser.add_argument(
        "--max-genuine-pairs",
        type=int,
        default=DEFAULT_MAX_GENUINE_PAIRS,
        help="Upper bound on genuine pairs to score when the full set is large.",
    )
    parser.add_argument(
        "--max-impostor-pairs",
        type=int,
        default=DEFAULT_MAX_IMPOSTOR_PAIRS,
        help="Upper bound on impostor pairs to score when the full set is large.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=RANDOM_SEED,
        help="Random seed used for pair sampling.",
    )
    parser.add_argument(
        "--algorithm",
        choices=shared_algorithms(),
        default="modern",
        help="Which registered matching.py algorithm to benchmark.",
    )
    args = parser.parse_args()
    return BenchmarkConfig(
        max_genuine_pairs=args.max_genuine_pairs,
        max_impostor_pairs=args.max_impostor_pairs,
        seed=args.seed,
        algorithm=args.algorithm,
    )


def main():
    try:
        config = parse_args()
        users = load_users()
        if not users:
            message = "No valid templates found in uidai.db"
            write_error_csv(message)
            write_plot([], None, message)
            logger.info(message)
            return

        genuine_pairs, impostor_pairs, total_impostor_pairs, total_genuine_pairs, mode = build_pairs(
            users,
            config.max_genuine_pairs,
            config.max_impostor_pairs,
            config.seed,
        )
        prepared_lookup = {user["id"]: user["prepared"] for user in users}

        genuine_scores = score_pairs(genuine_pairs, prepared_lookup, algorithm=config.algorithm)
        impostor_scores = score_pairs(impostor_pairs, prepared_lookup, algorithm=config.algorithm)
        rows, eer_row = compute_metrics(genuine_scores, impostor_scores)

        write_csv(rows, eer_row)
        write_plot(rows, eer_row)

        logger.info(f"Algorithm: {config.algorithm}")
        logger.info(f"Loaded users: {len(users)}")
        logger.info(f"Benchmark mode: {mode}")
        logger.info(f"Genuine pairs used: {len(genuine_pairs)}")
        logger.info(f"Genuine pairs available: {total_genuine_pairs}")
        logger.info(f"Impostor pairs used: {len(impostor_pairs)}")
        logger.info(f"Impostor pairs available: {total_impostor_pairs}")
        if total_genuine_pairs:
            logger.info(f"Genuine coverage: {len(genuine_pairs) / total_genuine_pairs:.2%}")
        if total_impostor_pairs:
            logger.info(f"Impostor coverage: {len(impostor_pairs) / total_impostor_pairs:.2%}")
        logger.info(f"Wrote CSV: {CSV_PATH}")
        if plt is not None:
            logger.info(f"Wrote plot: {PLOT_PATH}")
        else:
            logger.info("Skipped plot: matplotlib is not installed.")
        if eer_row:
            logger.info(f"EER ~ {eer_row['eer']:.4f} at threshold {eer_row['threshold']:.1f}")
            logger.info(
                "At EER threshold: "
                f"FAR={eer_row['far']:.4f}, FRR={eer_row['frr']:.4f}"
            )
        else:
            logger.info("EER unavailable: need both genuine and impostor pairs.")

    except Exception as exc:
        write_error_csv(str(exc))
        write_plot([], None, str(exc))
        logger.exception(f"Benchmark failed: {exc}")


if __name__ == "__main__":
    main()
