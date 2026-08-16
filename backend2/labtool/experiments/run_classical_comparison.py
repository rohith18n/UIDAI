"""
Closed-loop test: does classical_enhancement.py's Tier-0 preprocessing change what
MinutiaeNet actually extracts, for better or worse?

Not a visual comparison — this runs the real local pipeline (the same models the
server uses, imported directly and run in-process) on real team photos, produces two
preprocessed images per photo (the server's own preprocess_fingerprint, and the
classical alternative), extracts minutiae from both with the exact same
detect_minutiae code, and reports:

  1. Minutiae count, server vs. classical.
  2. Self-consistency: match_templates(minutiae_server, minutiae_classical) for the
     SAME photo — do the two preprocessing paths agree on largely the same ridge
     structure? A low score here means they're extracting different things, not
     necessarily that one is wrong.
  3. The real-world question: if a NEW capture were preprocessed the classical way,
     would it still correctly identify against the EXISTING gallery (which was
     enrolled with the server's own preprocessing)? Scored against every other
     gallery entry via the full matcher registry's "modern" algorithm.

Run from backend/: `python -m labtool.experiments.run_classical_comparison`
Requires the local backend's model weights to be present (backend/*.pt, *.pth, *.h5,
*.tflite) and TensorFlow installed — the same local setup used earlier in this
project, not a network call to any server.
"""

import sys
import time
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import cv2  # noqa: E402

from labtool import gallery  # noqa: E402
from labtool.experiments.classical_enhancement import classical_enhance  # noqa: E402

MAX_PHOTOS = 5  # keep runtime reasonable on CPU-only local inference


def main():
    import app  # noqa: E402  (heavy import — TF/torch/YOLO — deferred until here)
    import matching  # noqa: E402

    print("Loading models...")
    app.load_models()
    if "minutiae" not in app.global_models:
        print("MinutiaeNet weights not found locally — nothing to compare. "
              "See CLAUDE.md's model-weights section.")
        return

    dataset_dir = Path(__file__).resolve().parent.parent / "dataset"
    photos = sorted(dataset_dir.glob("*.jpeg")) + sorted(dataset_dir.glob("*.jpg"))
    if not photos:
        print(f"No photos found in {dataset_dir} — enrol some on the Dataset tab first.")
        return
    photos = photos[:MAX_PHOTOS]

    existing_gallery = gallery.list_templates()
    print(f"Comparing {len(photos)} photo(s) against a {len(existing_gallery)}-entry "
          f"existing gallery.\n")

    rows = []
    for path in photos:
        uid = path.stem.split("_f")[0]
        t0 = time.perf_counter()

        raw = cv2.imread(str(path))
        if raw is None:
            print(f"  {path.name}: could not read, skipping")
            continue

        try:
            cropped, det_conf = app.detect_and_crop(str(path))
        except ValueError as exc:
            print(f"  {path.name}: {exc}, skipping")
            continue

        mask = app.get_segmentation_mask(cropped)

        server_pre = app.preprocess_fingerprint(cropped, mask=mask)
        classical_pre = classical_enhance(cropped, mask=mask)

        minutiae_server = app.detect_minutiae(server_pre)
        minutiae_classical = app.detect_minutiae(classical_pre)

        self_consistency = matching.match_templates(
            minutiae_server, minutiae_classical, algorithm="modern")

        # The real question: would a classically-preprocessed NEW capture still find
        # the right person in the EXISTING (server-preprocessed) gallery?
        own_entry = next((e for e in existing_gallery if e["uid"] == uid), None)
        rank1_name, rank1_score, own_rank, own_score = "—", 0.0, None, None
        if existing_gallery:
            scored = sorted(
                ((e, matching.match_templates(minutiae_classical, e["minutiae"],
                                              algorithm="modern"))
                 for e in existing_gallery),
                key=lambda x: -x[1])
            rank1_name, rank1_score = scored[0][0]["name"], scored[0][1]
            if own_entry is not None:
                for rank, (entry, score) in enumerate(scored, start=1):
                    if entry["uid"] == uid:
                        own_rank, own_score = rank, score
                        break

        elapsed = time.perf_counter() - t0
        rows.append({
            "photo": path.name, "uid": uid,
            "n_server": len(minutiae_server), "n_classical": len(minutiae_classical),
            "self_consistency": self_consistency,
            "rank1_name": rank1_name, "rank1_score": rank1_score,
            "own_rank": own_rank, "own_score": own_score,
            "elapsed_s": elapsed,
        })
        print(f"  {path.name:<20} minutiae server={len(minutiae_server):<3} "
              f"classical={len(minutiae_classical):<3} "
              f"self-consistency={self_consistency:.3f} "
              f"rank1={rank1_name} (own rank {own_rank}) "
              f"[{elapsed:.1f}s]")

    if not rows:
        print("\nNothing scored.")
        return

    n_server_total = sum(r["n_server"] for r in rows)
    n_classical_total = sum(r["n_classical"] for r in rows)
    correct_rank1 = sum(1 for r in rows if r["own_rank"] == 1)
    print(f"\nTotals: server minutiae={n_server_total}, classical minutiae="
          f"{n_classical_total} ({n_classical_total / max(1, n_server_total):.2f}x)")
    print(f"Classically-preprocessed probe still ranks its own gallery entry #1: "
          f"{correct_rank1}/{len(rows)}")
    print(f"Mean self-consistency (server vs. classical, same photo): "
          f"{sum(r['self_consistency'] for r in rows) / len(rows):.3f}")


if __name__ == "__main__":
    main()
