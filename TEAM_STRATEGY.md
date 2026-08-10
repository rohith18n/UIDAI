# YellowSense Technologies — UIDAI SITAA Cohort 1
## Project Strategy, Status & Team Allocation

**Project ID:** SU-C1-2025-02  
**App Name:** `yellowsense_uidai`  
**Version:** 1.0.0+1  
**Stack:** Flutter 3.41.4 (Android/iOS) + Flask (Python 3.11) + PyTorch + TensorFlow  
**Team:** Atharv · Ishita · Ashish · Vignesh · Nandhini

---

## Role Boundaries (Read This First)

| Person | Domain |
|--------|--------|
| **Atharv** | Tech Lead — Flutter UI + backend integration + CI/CD |
| **Ishita** | Flutter UI + backend integration + QC screen wiring |
| **Ashish** | Backend only + Streamlit QC Tool |
| **Vignesh** | Backend only + Streamlit QC Tool |
| **Nandhini** | Backend only (no Flutter, no Streamlit) |

> Nandhini and Vignesh do **pure Python backend** work only.  
> Streamlit (desktop QC tool) is owned by **Ashish and Vignesh**.  
> All Flutter UI work goes to **Atharv or Ishita**.

---

## 1. What We Have Built

### 1.1 Flutter Mobile App (`lib/`)

| Screen | File | Status |
|--------|------|--------|
| Splash Screen | `screens/splash_screen.dart` | ✅ Done |
| Home Screen | `screens/home_screen.dart` | ✅ Done |
| Enroll User | `screens/enroll_screen.dart` | ✅ Done |
| Authenticate (1:N) | `screens/authenticate_screen.dart` | ✅ Done |
| Verify (1:1) | `screens/screens.dart → VerifyScreen` | ✅ Done |
| Pipeline Visualizer | `screens/pipeline_screen.dart` | ✅ Done |
| Auth History | `screens/screens.dart → HistoryScreen` | ✅ Done |
| Settings | `screens/screens.dart → SettingsScreen` | ✅ Done |
| QC Screen | `screens/screens.dart → QcScreen` | ✅ Done |

### 1.2 Flask Backend (`backend/app.py`)

| Function | What it does | Status |
|----------|-------------|--------|
| `detect_and_crop()` | YOLO finger detection + crop | ✅ |
| `check_liveness()` | MobileNetV2 live/spoof | ✅ |
| `get_segmentation_mask()` | U2Net TFLite foreground mask | ✅ |
| `preprocess_fingerprint()` | Zero-DCE / CLAHE + threshold + ROI | ✅ |
| `detect_minutiae()` | MinutiaeNet → x,y,direction,type | ✅ |
| `check_blur()` | Laplacian variance | ✅ |
| `check_brightness()` | Mean luminance | ✅ |
| `check_glare()` | bright_spot model + pixel fallback | ✅ |
| `quality_gate()` | Combined check + guidance string | ✅ |
| `match_templates()` | MCC graph + relaxation labeling | ✅ |

### 1.3 API Endpoints

| Endpoint | Method | Status |
|----------|--------|--------|
| `/health` | GET | ✅ |
| `/enroll` | POST | ✅ |
| `/authenticate` | POST | ✅ |
| `/verify` | POST | ✅ |
| `/quality_check` | POST | ✅ |
| `/process` | POST | ✅ |
| `/users` | GET | ✅ |
| `/history` | GET | ✅ |

---

## 2. What Is Missing

### 🔴 High Priority

| # | Feature | UIDAI Criteria |
|---|---------|----------------|
| M1 | Auto-capture — camera triggers when quality passes | e, h |
| M2 | Real-time guidance overlay on camera viewfinder | b, e |
| M3 | Finger-in-oval ROI check endpoint | b, e |

### 🟡 Medium Priority

| # | Feature | UIDAI Criteria |
|---|---------|----------------|
| M4 | Readiness Score 0–100 (composite quality metric) | b |
| M5 | ISO/IEC 19794-4 template export | d, g |
| M6 | QC Desktop Tool (Streamlit) | b, f |
| M7 | Contact-based fingerprint preprocessing | b, h |
| M8 | FAR/FRR benchmarking script | a |
| M9 | Gesture-based liveness challenge | c, h |

---

## 3. Team Allocation

### 👤 Atharv — Tech Lead · Flutter + CI/CD

**Domain:** Flutter UI, GitHub setup, CI/CD  
**Branch:** `feature/atharv-autocapture`

| Task | File | Priority |
|------|------|----------|
| Auto-capture — stream frames to `/quality_check`, auto-trigger when passed | `lib/widgets/fingerprint_camera_widget.dart` | 🔴 |
| Real-time guidance text overlay on camera viewfinder | `lib/widgets/fingerprint_camera_widget.dart` | 🔴 |
| Wire ROI guidance from `/check_roi` into camera widget (Vignesh builds endpoint) | `lib/widgets/fingerprint_camera_widget.dart` | 🔴 |
| Wire readiness score into QC screen (Nandhini builds endpoint) | `lib/screens/screens.dart → QcScreen` | 🟡 |
| GitHub repo setup — push code, add collaborators, protect `main` | GitHub | 🔴 |
| CI/CD — `.github/workflows/ci.yml` already created, push and verify | `.github/workflows/ci.yml` | 🔴 |

---

### 👤 Ishita — Flutter UI + Backend Integration

**Domain:** Flutter UI, wiring new backend endpoints into screens  
**Branch:** `feature/ishita-ui`

| Task | File | Priority |
|------|------|----------|
| Update QC screen to show readiness score (0–100 + grade) from `/readiness` | `lib/screens/screens.dart → QcScreen` | 🟡 |
| Add shimmer loading states on all screens while waiting for server | All screens | 🟡 |
| Add server-offline error state with retry button on all screens | All screens | 🟡 |
| Add haptic feedback on capture success and auth result | `lib/widgets/fingerprint_camera_widget.dart` | 🟢 |
| Add empty state on History screen when no records | `lib/screens/screens.dart → HistoryScreen` | 🟢 |
| Wire gesture liveness screen into enroll flow (Nandhini builds backend) | `lib/screens/enroll_screen.dart` | 🟡 |

---

### 👤 Ashish — Backend + Streamlit QC Tool

**Domain:** Pure Python — `backend/app.py` + `backend/qctool/`  
**Branch:** `feature/ashish-iso-qctool`

| Task | File | Priority |
|------|------|----------|
| ISO/IEC 19794-4 template export — `export_iso_template(minutiae)` function | `backend/app.py` | 🟡 |
| `/export_template` POST endpoint — returns base64 ISO binary | `backend/app.py` | 🟡 |
| Contact-based fingerprint preprocessing — port from old backend | `backend/app.py` | 🟡 |
| `/process_contact` POST endpoint | `backend/app.py` | 🟡 |
| QC Desktop Tool — **Tab 1: Image Quality** (blur/brightness/glare scores) | `backend/qctool/app.py` | 🟡 |
| QC Desktop Tool — **Tab 3: Contact vs Contactless Comparison** (SSIM/ORB/SIFT) | `backend/qctool/app.py` | 🟡 |
| Port `compare_images.py` and `annotate.py` from IIT Bombay repo | `backend/qctool/` | 🟡 |

**ISO 19794-4 reference:** https://www.iso.org/standard/50864.html  
**Contact preprocessing reference:** `contactless_attendance/backend/app.py → preprocess_contact_fingerprint()`

---

### 👤 Vignesh — Backend + Streamlit QC Tool

**Domain:** Pure Python — `backend/app.py` + `backend/qctool/`  
**Branch:** `feature/vignesh-roi-benchmark`

| Task | File | Priority |
|------|------|----------|
| `/check_roi` POST endpoint — YOLO bbox center vs image center, return offset + guidance | `backend/app.py` | 🔴 |
| FAR/FRR benchmark script — genuine + impostor pairs, EER at thresholds | `backend/benchmark.py` (new) | 🟡 |
| QC Desktop Tool — **Tab 2: Readiness Scoring** (minutiae count, clarity, accept/reject) | `backend/qctool/app.py` | 🟡 |
| QC Desktop Tool — **Tab 4: Contact Upload + preprocessing** (wire Ashish's `/process_contact`) | `backend/qctool/app.py` | 🟡 |

**`/check_roi` spec:**
```python
# Input: image file
# Steps: run YOLO → get bbox center → compare to image center
# Output:
{
  "in_roi": bool,
  "offset_x": float,   # pixels from center, negative = left
  "offset_y": float,   # pixels from center, negative = up
  "guidance": str      # "Move left", "Move right", "Move up", "Move down", "Good"
}
```

**`benchmark.py` spec:**
```python
# Load all users from uidai.db
# For each user with 2+ enrollments → genuine pair
# Cross-user pairs → impostor pairs
# Run match_templates() on all pairs
# Compute FAR, FRR at thresholds 0.1 to 0.9
# Output: benchmark_results.csv + eer_plot.png
```

---

### 👤 Nandhini — Backend Only

**Domain:** Pure Python — `backend/app.py` only  
**Branch:** `feature/nandhini-backend`

| Task | File | Priority |
|------|------|----------|
| `/readiness` POST endpoint — composite score 0–100 | `backend/app.py` | 🟡 |
| Gesture-based liveness — port `gesture.py` from IIT Bombay `Gesture` branch | `backend/app.py` | 🟡 |
| `/liveness_gesture` POST endpoint — random finger count challenge | `backend/app.py` | 🟡 |

**`/readiness` spec:**
```python
# Input: image file
# Steps:
#   1. Run quality_gate() → blur_score, brightness, glare
#   2. Run full pipeline → get minutiae count
#   3. Normalize each metric to 0–1
#   4. Weighted sum:
#      score = (blur_norm*30) + (brightness_norm*25) + (glare_norm*20) + (minutiae_norm*25)
# Output:
{
  "readiness_score": int,   # 0–100
  "grade": str,             # "Excellent" / "Good" / "Marginal" / "Rejected"
  "breakdown": {
    "blur": float,
    "brightness": float,
    "glare": float,
    "minutiae": int
  }
}
```

**`/liveness_gesture` spec:**
```python
# Input: image file + expected_count (int 1–5)
# Steps: run MediaPipe hand detection → count extended fingers
# Output:
{
  "detected_count": int,
  "expected_count": int,
  "passed": bool
}
```

---

## 4. Branch Strategy

```
main          ← protected, only merged PRs, requires 1 approval
develop       ← integration branch, everyone merges here first
  └── feature/atharv-autocapture
  └── feature/ishita-ui
  └── feature/ashish-iso-qctool
  └── feature/vignesh-roi-benchmark
  └── feature/nandhini-backend
```

**Rules:**
- Never commit directly to `main` or `develop`
- Always work on your own `feature/` branch
- Raise a PR to `develop` when your task is done
- Atharv reviews and approves all PRs
- CI must pass (green) before merge is allowed
- `develop` → `main` only at end of each sprint

---

## 5. Sprint Plan

### Sprint 1 — Week 1
| Person | Task | Done When |
|--------|------|-----------|
| Atharv | GitHub setup + CI passing | Green CI on first PR |
| Atharv | Auto-capture frame streaming | Camera auto-triggers |
| Ishita | Shimmer + error states on all screens | No blank screens |
| Ashish | `/process_contact` endpoint | `curl` test passes |
| Vignesh | `/check_roi` endpoint | Returns guidance string |
| Nandhini | `/readiness` endpoint | Returns 0–100 score |

### Sprint 2 — Week 2
| Person | Task | Done When |
|--------|------|-----------|
| Atharv | Real-time guidance overlay | Text shows on camera |
| Ishita | QC screen shows readiness score | Score visible in app |
| Ashish | ISO 19794-4 export + QC Tool Tab 1 & 3 | Streamlit tabs working |
| Vignesh | FAR/FRR script + QC Tool Tab 2 & 4 | CSV + plot generated |
| Nandhini | Gesture liveness endpoint | Challenge passes/fails correctly |

### Sprint 3 — Week 3
| Person | Task | Done When |
|--------|------|-----------|
| Atharv | ROI guidance wired into camera | Live alignment feedback |
| Ishita | Gesture liveness screen in Flutter | Full challenge flow |
| Ashish | ISO template wired into enroll | Template exported on enroll |
| Vignesh | QC Tool fully integrated | All 4 tabs working |
| Nandhini | End-to-end backend test | All endpoints tested with curl |
| Atharv | Final APK + submission prep | Release APK built |

---

## 6. Definition of Done

**Backend task is done when:**
1. Function written in `backend/app.py`
2. Tested locally with `curl` or Postman
3. No existing endpoints broken
4. PR raised to `develop`
5. CI passes
6. Atharv approves

**Flutter task is done when:**
1. Screen/widget updated
2. `flutter build apk --debug` passes locally
3. Tested on physical device or emulator
4. PR raised to `develop`
5. CI passes
6. Atharv approves

---

## 7. Resources

| Resource | Link |
|----------|------|
| IIT Bombay Repo | `github.com/prathameshsanaye28/UIDAI-IITB-CONTACTLESS` (private — ish1416 has access) |
| UIDAI Problem Statement | `SITAA/uidai.pdf` |
| ISO 19794-4 | https://www.iso.org/standard/50864.html |
| Flutter Docs | https://docs.flutter.dev |
| Flask Docs | https://flask.palletsprojects.com |
| Streamlit Docs | https://docs.streamlit.io |

---

*YellowSense Technologies · SITAA Cohort 1 · 2025*
