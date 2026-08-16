"""
Classical (non-ML) contactless fingerprint enhancement — intrinsic image
decomposition + guided filtering.

Zero-DCE, the current enhancement step (`app.py:preprocess_fingerprint`), is a
generic low-light image enhancer with no notion of ridge structure — it only fires
when mean luminance is below 150, and does nothing about uneven lighting *within* an
already-bright frame (a real failure mode for a hand-held photo with a shadow across
part of the finger). This is a Tier-0 alternative from PIPELINE_ALGORITHMS.md: no
training data, no new model weights, no new dependency — a hand-rolled guided filter
(He, Sun & Tang, "Guided Image Filtering", ECCV 2010) built entirely from
`cv2.boxFilter`, deliberately avoiding `cv2.ximgproc.guidedFilter` because that lives
in `opencv-contrib-python`, a different package than what's pinned in
requirements.txt.

MECHANISM
---------
1. Split the image into illumination (shading) and reflectance (ridge pattern)
   components in the log domain: a large-kernel low-pass of log-intensity estimates
   the slowly-varying shading; subtracting it leaves the fine ridge texture behind,
   largely independent of how the finger happened to be lit.
2. Guided-filter the reflectance against itself — edge-preserving smoothing that
   denoises without blurring ridge boundaries, unlike a plain Gaussian blur.
3. Feed the result through the exact same adaptive-threshold binarisation
   `preprocess_fingerprint` already uses, so the output is a direct drop-in — same
   shape, same value range, same downstream contract (`enhance_for_minutiae` /
   `detect_minutiae` neither know nor care which enhancement produced their input).

This is not wired into `app.py` or any production endpoint — see
`run_classical_comparison.py` in this package for the closed-loop test harness that
decides whether it's worth doing that.
"""

import cv2
import numpy as np


def _guided_filter(guide, src, radius=8, eps=1e-2):
    """
    He, Sun & Tang (2010), self-guided case (guide == src): edge-preserving
    smoothing built entirely from box filters — no `cv2.ximgproc` dependency.
    `guide`/`src` are float32 in [0, 1]; returns float32 in [0, 1].
    """
    mean_g = cv2.boxFilter(guide, -1, (radius, radius))
    mean_s = cv2.boxFilter(src, -1, (radius, radius))
    mean_gs = cv2.boxFilter(guide * src, -1, (radius, radius))
    cov_gs = mean_gs - mean_g * mean_s
    mean_gg = cv2.boxFilter(guide * guide, -1, (radius, radius))
    var_g = mean_gg - mean_g * mean_g

    a = cov_gs / (var_g + eps)
    b = mean_s - a * mean_g

    mean_a = cv2.boxFilter(a, -1, (radius, radius))
    mean_b = cv2.boxFilter(b, -1, (radius, radius))
    return mean_a * guide + mean_b


def _estimate_reflectance(gray_u8, shading_kernel_frac=0.25):
    """
    Log-domain intrinsic decomposition: reflectance = log(I) - log(shading).

    `shading_kernel_frac` sets the low-pass kernel as a fraction of the image's
    shorter side — large enough to capture broad lighting gradients (a shadow across
    part of the finger), small enough to leave ridge-scale texture in the reflectance
    term rather than smoothing it away too.
    """
    gray = np.clip(gray_u8.astype(np.float32), 1.0, 255.0)
    log_i = np.log(gray)

    k = int(min(gray.shape[:2]) * shading_kernel_frac)
    k = max(15, k | 1)  # odd, and never smaller than a sane minimum
    shading_log = cv2.GaussianBlur(log_i, (k, k), 0)

    reflectance_log = log_i - shading_log
    reflectance = np.exp(reflectance_log)
    lo, hi = reflectance.min(), reflectance.max()
    if hi - lo < 1e-6:
        return gray_u8  # degenerate (near-flat) input — nothing to decompose
    normalised = (reflectance - lo) / (hi - lo)
    return (normalised * 255.0).astype(np.uint8)


def classical_enhance(cropped_bgr, mask=None):
    """
    Drop-in alternative to `app.py:preprocess_fingerprint`'s enhancement step.

    Takes the same inputs (cropped BGR finger image, optional binary segmentation
    mask) and returns the same shape of output: a single-channel uint8 binary image,
    ridges dark on a white background, matching the contract `detect_minutiae`
    already expects — so it can be substituted for the server's own preprocessed
    image with no other code changes.
    """
    gray = cv2.cvtColor(cropped_bgr, cv2.COLOR_BGR2GRAY)
    if mask is not None:
        gray = np.where(mask.astype(bool), gray, 255).astype(np.uint8)

    reflectance = _estimate_reflectance(gray)
    filtered = _guided_filter(
        reflectance.astype(np.float32) / 255.0,
        reflectance.astype(np.float32) / 255.0,
    )
    filtered_u8 = np.clip(filtered * 255.0, 0, 255).astype(np.uint8)

    thresh = cv2.adaptiveThreshold(filtered_u8, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                                   cv2.THRESH_BINARY, 15, 1)
    inv = 255 - thresh
    if mask is not None:
        inv[~mask.astype(bool)] = 255
    return inv
