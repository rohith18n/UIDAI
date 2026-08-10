# Raj — Test Report

**Date:** 2026-06-01
**Backend version:** `13ed909` (Merge PR #5 — feature/ashish-iso-qctool)
**Test environment:** macOS (Apple Silicon), Python 3.11.15 (installed via `uv`), backend on `cpu`
**Server:** `http://10.173.127.198:5001` — `/health` → `status: ok`
**Test image:** real fingerprint captured by app (`20260531_184923_fp.jpg`)

---

## Environment Setup Notes

- Python 3.11 was **not** installed; `brew install python@3.11` failed (needs Xcode Command Line Tools). Installed a standalone Python 3.11.15 via `uv` instead — works fine.
- `backend/start.sh` contains a **hardcoded venv path** to another machine (`/Users/ath1614/...`) — see Bug #2. Started server directly with `./venv/bin/python app.py`.
- 5/5 ML models load: U²Net, Zero-DCE, MinutiaeNet, Liveness (threshold 0.3), Bright-spot.
- **mediapipe was broken** (Bug #1) — fixed during testing by pinning `mediapipe==0.10.21`.

---

## API Tests

| Test | Endpoint | Result | Notes |
|------|----------|--------|-------|
| T1.1 | GET /health | ✅ PASS | status ok; all model flags true (after mediapipe fix). |
| T1.2 | POST /quality_check | ✅ PASS | Returns passed/guidance/blur/brightness/glare. No image → 400. |
| T1.3 | POST /enroll | ✅ PASS | success; **55 minutiae**; liveness is_live=true (0.85); detection 0.918. Missing fields → 400. |
| T1.4 | POST /authenticate | ✅ PASS | 1:N match → name "Raj Test", uid RAJ001, **confidence 1.0**. No batch → 400. |
| T1.5 | POST /verify | ✅ PASS | matched=true, confidence 1.0; **wrong uid → HTTP 404** (correct). |
| T1.6 | POST /process | ✅ PASS | quality passed, 55 minutiae, images: cropped/preprocessed/visualization. |
| T1.7 | POST /readiness | ✅ PASS | readiness_score **69**, grade "Good", breakdown (blur 31.6, bright 111.5, glare false, minutiae 55). |
| T1.8 | POST /check_roi | ✅ PASS | no image → 400; no finger → 422 "Place finger in view". |
| T1.9 | POST /process_contact | ✅ PASS | success; **99 minutiae**; images: processed/visualization. |
| T1.10 | POST /compare_contact | ⚠️ PARTIAL | Endpoint works (success=true) but **similarity_score 0, matches 0** with two different captures. Needs a true contact+contactless pair of the SAME finger to validate a positive score. See Note A. |
| T1.11 | POST /export_template | ✅ PASS | success, 55 minutiae, ISO template base64 `Rk1S...` (= "FMR" header). **Response key is `template`, not `iso_template`** (doc mismatch — see Note B). |
| T1.12 | POST /liveness_gesture | ✅ PASS (after fix) | Was HTTP 501 (Bug #1). After fixing mediapipe → HTTP 200, returns detected_count/expected_count/passed. |
| T1.13 | GET /users | ✅ PASS | Returns enrolled users (Raj/BTech, Raj Test/RAJ_TEST). |
| T1.14 | GET /history | ✅ PASS | Returns auth history rows. |
| T1.15 | GET /health (regression) | ✅ PASS | Still status ok after all calls. |

**Score: 13 PASS, 1 PASS-after-fix (T1.12), 1 PARTIAL (T1.10).**

### Note A — /compare_contact
Tested with two different fingerprint captures → similarity_score 0. The endpoint runs without error, but to truly validate the comparison logic it needs a matched **contact + contactless image of the same finger**. Could not produce a positive case with available images. (Owner: Ashish)

### Note B — /export_template response key
Onboarding guide expects `iso_template` in the response, but `app.py` returns the key `template`. App/clients should use `template`. Also the ISO header is the simplified 6-byte form (see P3 — Ashish).

### Not tested (needs a 2nd person's finger)
- Authenticate with a different person → expect "No match found". Only one finger available, so the negative 1:N case is untested.

---

## App Tests (APK on physical Android device — confirmed working)

| Test | Screen | Result | Notes |
|------|--------|--------|-------|
| — | APK install + launch | ✅ PASS | App runs on physical device over USB. |
| T4.2 | Settings | ✅ PASS | Server URL must be set to `http://10.173.127.198:5001`. App resets to default `192.168.101.3` on rebuild — see Note C. /health reachable from phone browser. |
| T4.3 | Enroll | ✅ PASS | Enrolled Raj/BTech successfully from the app. (Gesture-liveness gate now hidden — see Change #2.) |
| T4.1, T4.4–T4.12 | Splash, Auth, Verify, Pipeline, QC, History, Shimmer, Offline, Haptic, Auto-capture | 🟡 PARTIAL | App confirmed working end-to-end; per-screen checklist not individually recorded. |
| — | Gesture Liveness | ⚠️ KNOWN-ISSUE | Finger counting unreliable (thumb / orientation — Bug #3). Temporarily hidden from enroll flow via feature flag pending fix. |

### Note C — App default server URL
On rebuild the app resets the saved server URL to `192.168.101.3:5001` (a hardcoded default). Should default to a configurable/empty value or current host. (Owner: Atharv)

---

## Benchmark

| Item | Result |
|------|--------|
| benchmark.py run | ⏳ PENDING |
| benchmark_results.csv | ⏳ PENDING |
| eer_plot.png | ⏳ PENDING |
| EER value | ⏳ PENDING |

> Note: only 1–2 users enrolled; benchmark needs more enrolled users for meaningful FAR/FRR.

---

## QC Tool (Streamlit)

| Tab | Result | Notes |
|-----|--------|-------|
| Tab 2 Readiness | ⏳ PENDING | Needs `streamlit run` |
| Tab 4 Contact | ⏳ PENDING | Needs `streamlit run` |
| Tab 1 Image Quality | ❌ NOT IMPLEMENTED | Empty placeholder — Ashish (P1) |
| Tab 3 Comparison | ❌ NOT IMPLEMENTED | Empty placeholder — Ashish (P2) |

---

## Bugs Found

| # | Severity | Description | Assigned To | Status |
|---|----------|-------------|-------------|--------|
| 1 | High | `/liveness_gesture` returned HTTP 501 "mediapipe not available". Root cause: `mediapipe>=0.10.0` installed broken stub wheel `0.10.35` (`py3-none-macosx_arm64`, no `solutions` module) on Apple Silicon. **FIXED** by pinning `mediapipe==0.10.21`. requirements.txt should pin this. | @Atharv / @Nandhini | **Fixed locally** (needs requirements.txt pin) |
| 2 | Low | `backend/start.sh` hardcodes a venv path to another machine (`/Users/ath1614/...`) — fails for everyone else. Should activate local `./venv`. | @Atharv | Open |
| 3 | Medium | Gesture finger-count unreliable. Thumb uses `landmarks[4].x < landmarks[3].x` (handedness/mirror dependent) and 4 fingers use `tip.y < pip.y` (assumes upright hand). "5" challenge often detects 4 (thumb missed). Suggest wrist-distance method + handedness. | @Nandhini | Open |
| 4 | Low | `/export_template` returns key `template`, but onboarding/docs reference `iso_template`. Align doc or code. ISO header also simplified 6-byte (P3). | @Ashish | Open |
| 5 | Low | App resets server URL to hardcoded `192.168.101.3:5001` on rebuild. | @Atharv | Open |

### Bug #1 detail
```
🐛 BUG — /liveness_gesture endpoint
What I did: curl -X POST /liveness_gesture -F image=@hand.jpg -F expected_count=3
Expected: detected_count + passed
Got: HTTP 501 "mediapipe is not available"
Root cause: mediapipe>=0.10.0 → pip installed broken stub wheel 0.10.35
(py3-none-macosx_11_0_arm64, no solutions module) on Apple Silicon.
Fix: pip install mediapipe==0.10.21 (ships cp311-universal2 wheel with solutions.hands).
Confirmed: /health mediapipe_available=true, endpoint now HTTP 200.
Severity: High → Fixed locally
Tag: @Atharv (pin in requirements.txt) / @Nandhini
```

---

## Changes Made During Testing (need PR + team review)

> These touch `lib/` (Atharv/Ishita's area) and were done at tester's request — flag in PR.

1. **Gesture liveness → back camera** ([lib/screens/gesture_liveness_screen.dart](lib/screens/gesture_liveness_screen.dart)): `CameraLensDirection.front` → `back`.
2. **Hid gesture-liveness gate in enroll** ([lib/screens/enroll_screen.dart](lib/screens/enroll_screen.dart)): added `_livenessEnabled = false` feature flag — enroll goes straight to fingerprint capture. Set back to `true` to re-enable. (Reason: Bug #3, to be re-integrated after fix.)
3. **mediapipe fix** (env only): `mediapipe==0.10.21` installed in venv.

---

## Summary

- **API tests:** 15 total — **13 PASS**, 1 PASS-after-fix (T1.12), 1 PARTIAL (T1.10). 1 negative case (different-person auth) untested.
- **App tests:** APK confirmed working on physical device; Enroll/Settings verified; full per-screen checklist pending.
- **Bugs raised:** 5 (1 High-fixed, 1 Medium, 3 Low).
- **Pending:** benchmark.py run, Streamlit QC Tool (Tab 2/4) test, full per-screen app checklist (T4.1–T4.12), messages to Ashish/Atharv/Nandhini, PR to develop.

---

*API testing completed against real fingerprint capture. Backend endpoints are functional. Remaining: benchmark, QC tool, per-screen app checklist, PR.*
