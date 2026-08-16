# On-Device / Cloud Integration Guide

For whoever's building the on-device Flutter/Dart pipeline. This is the practical
"what to build against, how to check your work, when to switch over" — the deeper
architecture reasoning lives in the project's planning notes; this is the
day-to-day reference.

## The target

```
Flutter app → on-device (capture → QC → liveness → segment → enhance)
            → preprocessed image
            → cloud /v2/* endpoints → templatization (minutiae) + matching
            → result
```

Today, none of the on-device stages exist yet — the app still sends a raw photo
to a server that runs the whole pipeline. That's fine; here's how to work through
the gap without breaking anything or duplicating work.

## Phase 1 — what to test against while you build

Keep using the existing endpoints exactly as the app does today — same raw photo
upload, same response shape:

- Single-finger: `/enroll`, `/authenticate`, `/verify` — currently served from
  `35.255.138.39:5002`
- Slap: `/enroll_slap`, `/authenticate_slap`, `/verify_slap` — currently served
  from `35.255.138.39:5010`

**Update, as of this writing**: both `:5002` and `:5010` were redeployed with the
matcher/security fixes documented in `bug.md` (liveness now genuinely enforced on
both flows, position-constrained slap matching, real glare/ROI checks, etc.) — so
capture accept/reject behavior on both now reflects real pipeline behavior, not a
bypass. One live consequence worth knowing: liveness rejections are more common
now than before, because the liveness model itself has known calibration issues
on some captures (bug.md #12) — a rejected capture during testing may be a real
liveness-model limitation, not something wrong with your on-device work. If a
specific test photo gets rejected unexpectedly, check its liveness confidence via
`/process` before assuming your code is at fault.

Don't change `ApiService`'s target yet. This phase is just "the app keeps
working while you build in parallel."

## Phase 2 — validating each on-device stage as you build it

You won't build the whole on-device chain in one shot. As you get each stage
working locally (detector, liveness, segmentation, enhancement), validate it
against the reference server's output for the *same input photo*:

- `POST /process` (single-finger reference, port 5002) runs the full pipeline on
  a raw photo and returns every intermediate stage: the cropped image, the
  segmentation mask's effect, the final preprocessed image, the minutiae list,
  per-stage confidence — `images: {original, cropped, preprocessed,
  visualization}`, `quality`, `liveness` (subject to the caveat above),
  `minutiae`.
- `POST /quality_check` (both ports) is the fast path — blur/brightness/glare/
  ROI only, no minutiae — useful for validating just the QC stage in isolation.

Concretely: run the same test photo through your on-device liveness model and
through `/process`'s `liveness` field, compare confidence scores. Once
segmentation is working, compare your local mask/preprocessed output against
`/process`'s `images.preprocessed`. No new backend endpoint is needed for this —
these already return exactly what's needed to diff against.

## Phase 3 — when to cut over

Once your full on-device chain (detect → QC → liveness → segment → enhance)
produces a final preprocessed image that matches what `/process`'s
`images.preprocessed` gives for the same photo, switch `ApiService` to the new
cloud endpoints and start uploading *that* preprocessed image instead of the raw
photo:

- Base URL: `https://34-100-150-103.sslip.io`
- Single-finger: `POST /v2/enroll`, `POST /v2/authenticate`, `POST /v2/verify`
- Slap: `POST /v2/enroll_slap`, `POST /v2/authenticate_slap`, `POST /v2/verify_slap`

### `/v2/enroll` — single-finger
Multipart fields: `image` (the preprocessed image, not a raw photo), `name`,
`uid`, `batch`, optional `finger_position` (0-10, default 0).
Response: `{"success": true, "minutiae_count": <int>}`.

### `/v2/authenticate` — single-finger, 1:N
Fields: `image`, `batch`.
Response on match: `{"success": true, "name", "uid", "confidence"}`.
No match: `{"success": false, "message": "No match found", "confidence"}`.

### `/v2/verify` — single-finger, 1:1
Fields: `image`, `uid`, `batch`.
Response: `{"success": true, "matched": bool, "confidence", "threshold", "name",
"uid", "input_minutiae_count"}`.

### `/v2/enroll_slap`, `/v2/authenticate_slap`, `/v2/verify_slap`
Same shapes as their single-finger counterparts, plus: repeated `image` file
fields — **one per finger, in left-to-right capture order** — and `hand_side`
(`left`/`right`, default `right`). Optional `finger_order` (comma-separated
position names) if your capture geometry doesn't match the default left-to-right
assumption. Slap responses include `matched_fingers` (per-finger detail) and
`avg_confidence` alongside the aggregate `confidence`.

Current matching config: `algorithm="legacy"`, `threshold=0.20` (both flows) —
subject to change once real accuracy calibration against the 85% gate happens;
don't hardcode assumptions about the threshold value into client logic beyond
"the server tells you `matched`/`success`."

## Model conversion reference (what's on-device tier)

| Model | Format today | Target | Notes |
|---|---|---|---|
| Finger detector (single-finger, `best-new.pt`) | PyTorch | TFLite via `ultralytics .export(format="litert")` | NMS not supported in TFLite export — decode+NMS in Dart, or use the `ultralytics_yolo` plugin |
| Finger detector (slap, `best_float32.tflite`) | **Already TFLite** | — | Different file from single-finger's; bundle directly |
| Glare detector | PyTorch, optional | TFLite, or drop it | Pixel-overexposure fallback (`gray>240` ratio `>0.05`) needs no model at all — reasonable to skip converting this one |
| Liveness (MobileNetV2) | PyTorch | TFLite via `litert-torch` (formerly `ai-edge-torch`) | Real threshold is **0.3**, not 0.5 — read from the checkpoint. 224×224 RGB, ImageNet-normalized. Must fail closed — a missing/corrupt model must reject, never silently pass |
| Segmentation (U²Net) | **Already TFLite** | — | `[1,320,320,3]f32` in, `[1,320,320,1]f32` out, then convex-hull-of-largest-contour cleanup — replicate the hull step, not just the raw network output |
| Enhancement (Zero-DCE) | Keras `.h5` | TFLite via `TFLiteConverter.from_keras_model` | Fires conditionally — only when mean luminance < 150; otherwise a hand-rolled histogram equalization runs instead (pure algorithmic, no model, but note it's deliberately biased by synthetic white background pixels — replicate, don't "fix") |

Full per-stage algorithm detail (exact preprocessing order, the central-ROI
erosion, the asymmetric bottom-only crop, etc.) — ask backend for the fuller
write-up if the table above isn't enough to implement against; it exists.
