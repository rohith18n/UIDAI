# YellowSense Technologies — UIDAI SITAA Cohort 1
## Raj Onboarding Guide

**Project ID:** SU-C1-2025-02  
**App Name:** `yellowsense_uidai`  
**Version:** 1.0.0+1  
**Stack:** Flutter 3.41.4 (Android/iOS) + Flask (Python 3.11) + PyTorch + TensorFlow  
**Repo:** https://github.com/ish1416/UIDAI  
**Your Branch:** `feature/raj-testing`

---

## Who You Are & What You Own

| Person | Domain |
|--------|--------|
| Atharv | Tech Lead — Flutter UI + backend integration + CI/CD |
| Ishita | Flutter UI + backend integration + QC screen wiring |
| Ashish | Backend + Streamlit QC Tool |
| Vignesh | Backend + Streamlit QC Tool |
| Nandhini | Backend only |
| **Raj** | **QA — API testing + App testing + Final validation** |

You do **not** write new features. Your job is to test everything that has been built, document results, and raise issues back to Atharv.

---

## What Has Been Built (Full Status)

### Flutter App — All screens done

| Screen | File | Status |
|--------|------|--------|
| Splash Screen | `lib/screens/splash_screen.dart` | ✅ Done |
| Home Screen | `lib/screens/home_screen.dart` | ✅ Done |
| Enroll User | `lib/screens/enroll_screen.dart` | ✅ Done |
| Authenticate (1:N) | `lib/screens/authenticate_screen.dart` | ✅ Done |
| Verify (1:1) | `lib/screens/screens.dart → VerifyScreen` | ✅ Done |
| Pipeline Visualizer | `lib/screens/pipeline_screen.dart` | ✅ Done |
| Auth History | `lib/screens/screens.dart → HistoryScreen` | ✅ Done |
| Settings | `lib/screens/screens.dart → SettingsScreen` | ✅ Done |
| QC Screen | `lib/screens/screens.dart → QcScreen` | ✅ Done |
| Gesture Liveness | `lib/screens/gesture_liveness_screen.dart` | ✅ Done |

### Flutter Features — All done

| Feature | Status |
|---------|--------|
| Auto-capture (quality polling every 900ms, triggers on 3 passes) | ✅ Done |
| Real-time guidance overlay on camera viewfinder | ✅ Done |
| ROI guidance from `/check_roi` wired into camera | ✅ Done |
| Readiness score (0–100 + grade + breakdown) on QC screen | ✅ Done |
| Shimmer loading states on all screens | ✅ Done |
| Server offline error card + retry on all screens | ✅ Done |
| Haptic feedback on capture success / auth result | ✅ Done |
| Empty state on History screen | ✅ Done |
| Gesture liveness challenge wired into enroll flow | ✅ Done |

### Backend Endpoints — All done

| Endpoint | Method | Owner | Status |
|----------|--------|-------|--------|
| `/health` | GET | Core | ✅ Done |
| `/enroll` | POST | Core | ✅ Done |
| `/authenticate` | POST | Core | ✅ Done |
| `/verify` | POST | Core | ✅ Done |
| `/quality_check` | POST | Core | ✅ Done |
| `/process` | POST | Core | ✅ Done |
| `/users` | GET | Core | ✅ Done |
| `/history` | GET | Core | ✅ Done |
| `/readiness` | POST | Nandhini | ✅ Done |
| `/liveness_gesture` | POST | Nandhini | ✅ Done |
| `/check_roi` | POST | Vignesh | ✅ Done |
| `/process_contact` | POST | Ashish | ✅ Done |
| `/compare_contact` | POST | Ashish | ✅ Done |
| `/export_template` | POST | Ashish | ✅ Done |

### Streamlit QC Tool — Partially done

| Tab | Owner | Status |
|-----|-------|--------|
| Tab 1: Image Quality | Ashish | ❌ Empty — not implemented |
| Tab 2: Readiness Scoring | Vignesh | ✅ Done |
| Tab 3: Contact vs Contactless Comparison | Ashish | ❌ Empty — not implemented |
| Tab 4: Contact Processing | Vignesh | ✅ Done |

### Other Deliverables

| Item | Owner | Status |
|------|-------|--------|
| `benchmark.py` — FAR/FRR script, EER, CSV + plot | Vignesh | ✅ Done |
| CI/CD `.github/workflows/ci.yml` | Atharv | ✅ Done |
| `flutter analyze` — 0 issues | Atharv | ✅ Clean |
| `flutter build apk --debug` | Atharv | ✅ Passes |

---

## Part 1 — Setting Up Your Laptop

### Step 1 — Install Required Tools

```bash
# Everyone needs Git
# https://git-scm.com/downloads

# Python 3.11
# Mac:
brew install python@3.11

# Windows:
# https://www.python.org/downloads/release/python-3110/
# Check "Add Python to PATH" during install

# Flutter SDK 3.41.4 (needed to build + run the app)
# https://docs.flutter.dev/get-started/install
# Android Studio + SDK 34 + Pixel 6 emulator (API 34)
```

---

### Step 2 — Clone the Repository

```bash
git clone https://github.com/ish1416/UIDAI.git
cd UIDAI
```

The folder structure:
```
UIDAI/
├── uidai_app/                  ← Flutter app
│   ├── lib/
│   │   ├── screens/            ← all app screens
│   │   ├── widgets/            ← camera widget
│   │   ├── services/           ← API calls
│   │   └── theme/              ← colors, fonts
│   ├── backend/                ← Flask server
│   │   ├── app.py              ← ALL backend code
│   │   ├── benchmark.py        ← FAR/FRR benchmark script
│   │   ├── qctool/
│   │   │   └── app.py          ← Streamlit QC desktop tool
│   │   ├── requirements.txt
│   │   └── start.sh
│   └── pubspec.yaml
└── .github/workflows/ci.yml
```

---

### Step 3 — Get the Model Files (IMPORTANT)

The AI model files are **not in Git** — they are too large. Download all of them from this Google Drive link:

**https://drive.google.com/drive/folders/1wBuuCHnEOVyjgeMwVvI2O_e54fX5emjk?usp=sharing**

Download every file and place them all inside `uidai_app/backend/`:

| File | What it does |
|------|-------------|
| `best-new.pt` | YOLO finger detector |
| `best_f1.pth` | MinutiaeNet (ridge/bifurcation detection) |
| `liveness_model_v3.pt` | MobileNetV2 liveness (live vs spoof) |
| `u2net_320x320_float32.tflite` | U²Net segmentation mask |
| `zero_dce_model.h5` | Zero-DCE image enhancement |
| `bright_spot_detection.pt` | Glare/bright-spot detector |
| `best_float32.tflite` | Finger coverage mask |
| `coverage_mask.tflite` | Coverage mask (backup) |

After downloading, your `uidai_app/backend/` folder must look like:
```
backend/
├── app.py
├── benchmark.py
├── best-new.pt
├── best_f1.pth
├── liveness_model_v3.pt
├── u2net_320x320_float32.tflite
├── zero_dce_model.h5
├── bright_spot_detection.pt
├── best_float32.tflite
├── coverage_mask.tflite
├── requirements.txt
├── start.sh
└── qctool/
    └── app.py
```

> The server will **not start** without these files. Do this before anything else.

---

### Step 4 — Backend Setup

#### Mac:
```bash
cd UIDAI/uidai_app/backend

# Create virtual environment
python3.11 -m venv venv

# Activate (do this every time you open a new terminal)
source venv/bin/activate

# Install all dependencies (includes mediapipe, streamlit, etc.)
pip install -r requirements.txt

# Mac Apple Silicon (M1/M2/M3) — replace tensorflow line with:
pip install tensorflow-macos==2.16.2 tensorflow-metal==1.2.0
```

#### Windows:
```powershell
cd UIDAI\uidai_app\backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
# If tensorflow fails:
pip install tensorflow-cpu
```

#### Verify install:
```bash
python -c "import flask, torch, cv2, ultralytics, tensorflow, mediapipe; print('ALL OK')"
```
You must see `ALL OK`. If any module fails, run `pip install <module-name>` again.

---

### Step 5 — Start the Backend Server

**Mac/Linux:**
```bash
cd uidai_app/backend
source venv/bin/activate
bash start.sh
```

**Windows:**
```powershell
cd uidai_app\backend
venv\Scripts\activate
python app.py
```

You should see:
```
✓ U2Net loaded
✓ Zero-DCE loaded
✓ MinutiaeNet loaded
✓ Liveness loaded
✓ Bright-spot detector loaded
* Running on http://0.0.0.0:5001
```

**Verify it's running:**
```bash
curl http://localhost:5001/health
```
Expected response:
```json
{
  "status": "ok",
  "device": "cpu",
  "liveness_available": true,
  "minutiae_available": true,
  "brightspot_available": true,
  "mediapipe_available": true
}
```

---

### Step 6 — Flutter Setup

```bash
cd UIDAI/uidai_app

# Check Flutter is installed
flutter doctor
# Fix any issues before continuing

# Install packages
flutter pub get

# Run on device or emulator
flutter run
```

**Connect the app to your backend:**
- Open the app → tap Settings (gear icon top right)
- Set URL to `http://<your-laptop-IP>:5001`
- Find your IP: Mac → `ipconfig getifaddr en0` | Windows → `ipconfig`
- Your phone and laptop must be on the **same WiFi**
- Emulator: use `http://10.0.2.2:5001`

---

### Step 7 — Create Your Branch

```bash
cd UIDAI/uidai_app
git checkout develop
git pull origin develop
git checkout -b feature/raj-testing
git push origin feature/raj-testing
```

---

## Part 2 — Your Tasks

---

### Task 1 — API Testing (Backend)

Test every endpoint with curl. Use any fingerprint image from `backend/uploads/` as your test image. Document pass/fail for each.

#### T1.1 — Health Check
```bash
curl http://localhost:5001/health
```
**Expected:** `status: ok`, all 4 model flags `true`, `mediapipe_available: true`

---

#### T1.2 — Quality Check
```bash
curl -X POST http://localhost:5001/quality_check \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** JSON with `passed` (bool), `guidance` (string), `blur`, `brightness`, `glare` objects.

Test with a blurry/dark image too and confirm `passed: false` with a meaningful `guidance` string.

---

#### T1.3 — Enroll
```bash
curl -X POST http://localhost:5001/enroll \
  -F "name=Test User" \
  -F "uid=TEST001" \
  -F "batch=RAJ_TEST" \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `minutiae_count` > 0, `liveness.is_live: true`, `visualization` (base64 image string).

Enroll at least **3 different UIDs** in batch `RAJ_TEST` for downstream tests.

---

#### T1.4 — Authenticate (1:N)
```bash
curl -X POST http://localhost:5001/authenticate \
  -F "batch=RAJ_TEST" \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `name`, `uid`, `confidence` > 0.25.

Also test with an image of a **different person** — expect `success: false`, `message: No match found`.

---

#### T1.5 — Verify (1:1)
```bash
curl -X POST http://localhost:5001/verify \
  -F "uid=TEST001" \
  -F "batch=RAJ_TEST" \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `matched: true`, `confidence` > 0.25.

Also test with wrong UID — expect `matched: false`.

---

#### T1.6 — Process (Pipeline only, no DB)
```bash
curl -X POST http://localhost:5001/process \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `quality` object, `liveness` object, `minutiae_count`, `images` object with `cropped`, `preprocessed`, `visualization` as base64 strings.

---

#### T1.7 — Readiness Score (Nandhini)
```bash
curl -X POST http://localhost:5001/readiness \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:**
```json
{
  "success": true,
  "readiness_score": <int 0-100>,
  "grade": "Excellent" | "Good" | "Marginal" | "Rejected",
  "breakdown": {
    "blur": <float>,
    "brightness": <float>,
    "glare": <bool>,
    "minutiae": <int>
  }
}
```
Test with multiple images. Confirm score changes meaningfully between a sharp and a blurry image.

---

#### T1.8 — Check ROI (Vignesh)
```bash
curl -X POST http://localhost:5001/check_roi \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:**
```json
{
  "success": true,
  "in_roi": <bool>,
  "offset_x": <float>,
  "offset_y": <float>,
  "guidance": "Good - finger centered" | "Move left" | "Move right" | "Move up" | "Move down",
  "detection_conf": <float>
}
```
Test with a centered finger image and an off-center one. Confirm guidance changes.

---

#### T1.9 — Process Contact (Ashish)
```bash
curl -X POST http://localhost:5001/process_contact \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `minutiae_count`, `images.processed` (base64), `images.visualization` (base64).

---

#### T1.10 — Compare Contact vs Contactless (Ashish)
```bash
curl -X POST http://localhost:5001/compare_contact \
  -F "contact=@backend/uploads/20260526_142758_fp.jpg" \
  -F "contactless=@backend/uploads/20260526_142801_fp.jpg"
```
**Expected:** `success: true`, `comparison.similarity_score` (int 0–100), `comparison.matches` (int).

---

#### T1.11 — Export ISO Template (Ashish)
```bash
curl -X POST http://localhost:5001/export_template \
  -F "image=@backend/uploads/20260526_142758_fp.jpg"
```
**Expected:** `success: true`, `minutiae_count` > 0, `iso_template` (base64 string starting with `Rk1S`).

---

#### T1.12 — Liveness Gesture (Nandhini)
```bash
curl -X POST http://localhost:5001/liveness_gesture \
  -F "image=@backend/uploads/20260526_142758_fp.jpg" \
  -F "expected_count=3"
```
**Expected:** `success: true`, `detected_count` (int), `expected_count: 3`, `passed` (bool).

> Note: This needs a hand image, not a fingerprint. Use your phone camera to take a photo of your hand showing fingers, then test.

---

#### T1.13 — List Users
```bash
curl "http://localhost:5001/users?batch=RAJ_TEST"
```
**Expected:** `users` array with the UIDs you enrolled in T1.3.

---

#### T1.14 — Auth History
```bash
curl "http://localhost:5001/history?batch=RAJ_TEST"
```
**Expected:** `history` array with timestamp, name, uid, confidence for each authentication you ran.

---

#### T1.15 — Regression: All original endpoints still work
After running all the above, run health check again:
```bash
curl http://localhost:5001/health
```
Must still return `status: ok`. Confirms nothing is broken.

---

### Task 2 — Benchmark Script (Vignesh)

```bash
cd uidai_app/backend
source venv/bin/activate
python benchmark.py
```

**Expected:**
- Script runs without crashing
- Prints loaded user count, genuine pairs, impostor pairs
- Generates `benchmark_results.csv` in `backend/`
- Generates `eer_plot.png` in `backend/`
- Prints approximate EER value and threshold

**Check the CSV:**
```bash
cat backend/benchmark_results.csv
```
Must have columns: `threshold, far, frr, false_accepts, false_rejects, total_genuine_pairs, total_impostor_pairs, eer_threshold, eer`

---

### Task 3 — Streamlit QC Tool

```bash
cd uidai_app/backend/qctool
pip install streamlit scikit-image scikit-learn requests
streamlit run app.py
# Opens at http://localhost:8501
```

**Tab 2 — Readiness Scoring:**
- Upload a fingerprint image
- Click "Run readiness assessment"
- Expected: score (0–100), grade badge, progress bar, breakdown bar chart, raw JSON

**Tab 4 — Contact Processing:**
- Upload a fingerprint image
- Click "Run contact processing"
- Expected: processed image preview, raw JSON response

**Tab 1 and Tab 3 — Document as NOT IMPLEMENTED**
These are empty placeholders. Raise this as a pending item for Ashish.

---

### Task 4 — Flutter App Testing

Build and install the debug APK first:

```bash
cd uidai_app
flutter pub get
flutter analyze          # must show: No issues found
flutter build apk --debug
# APK is at: build/app/outputs/flutter-apk/app-debug.apk
```

Install on your Android device:
```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
```
Or drag the APK onto an emulator.

---

#### T4.1 — Splash Screen
- Open the app
- Expected: YellowSense logo animates in, progress bar fills, transitions to Home after ~2.8 seconds
- No crash, no blank screen

---

#### T4.2 — Settings Screen
- Tap the gear icon (top right of Home)
- Set Server URL to `http://<your-laptop-IP>:5001`
- Tap **Save URL** → green snackbar "Saved"
- Tap **Check Health** → green card "Server Online" with all model flags shown
- Test with wrong IP → red card "Unreachable"

---

#### T4.3 — Enroll Screen
- Tap **Enroll** on Home
- Fill Name, UID, Batch
- Tap **Start Liveness Check** — gesture liveness screen opens
  - Shows a random number (1–5)
  - Front camera activates
  - Tap **Capture & Check** — shows pass/fail result
  - On pass → returns to Enroll with green "Liveness check passed ✓" badge
- Camera widget opens — test **AUTO mode**:
  - Quality bar appears at top of viewfinder
  - Guidance text shows at bottom ("Place finger inside the oval" / "Image is blurry" etc.)
  - ROI guidance shows if finger is off-center ("Move left" / "Move right" etc.)
  - Camera auto-triggers after 3 quality passes — flash, image captured
- Test **MANUAL mode** (tap AUTO toggle → MANUAL):
  - Capture button appears
  - Tap Capture → image captured
- Tap **Enroll User** → success card with minutiae count, liveness, detection confidence
- Test error states:
  - Submit with empty fields → red snackbar
  - Server offline → offline card with Retry button

---

#### T4.4 — Authenticate Screen (1:N)
- Tap **Authenticate** on Home
- Enter batch name (same one you enrolled into)
- Capture fingerprint (auto or manual)
- Expected: green "AUTHENTICATED" card with Name, UID, Confidence %
- Test with unknown fingerprint → red "NOT RECOGNIZED" card
- Test server offline → offline card with Retry

---

#### T4.5 — Verify Screen (1:1)
- Tap **Verify** on Home
- Enter Batch and UID of an enrolled user
- Capture fingerprint
- Expected: green "IDENTITY VERIFIED" card with Name, UID, match score bar
- Test with wrong UID → red "MISMATCH" card
- Test with correct UID but different finger → red "MISMATCH" card

---

#### T4.6 — Pipeline Visualizer
- Tap **Pipeline** on Home
- Capture a fingerprint
- Expected: 4 pipeline step cards appear in order:
  1. Original — raw image
  2. YOLO Crop — cropped finger
  3. Preprocessed — enhanced binary image
  4. Minutiae — visualization with dots and arrows
- Quality gate card (green/red) shown above pipeline
- Liveness card (green/red) shown
- Minutiae stats card at bottom (total, endings, bifurcations, progress bar)

---

#### T4.7 — QC Screen
- Tap **QC Pipeline** from Home (if accessible) or navigate via router
- Capture a fingerprint
- Expected: two cards appear:
  1. **Readiness Score card** — large number (0–100), grade badge (Excellent/Good/Marginal/Rejected), progress bar, 4 mini-stat boxes (Blur, Brightness, Glare, Minutiae)
  2. **Pipeline Results card** — Quality Gate pass/fail, blur score, brightness, glare, detection %, liveness, minutiae count

---

#### T4.8 — History Screen
- Tap **Auth History** on Home
- Tap **Load** with no batch → shows all history
- Tap **Load** with batch `RAJ_TEST` → shows only that batch
- Each row shows: name, UID, confidence %, timestamp
- Empty state: tap Load with a batch that has no records → shows history icon + "No records yet" + "Tap Load to fetch history"
- Server offline → offline card with Retry

---

#### T4.9 — Shimmer Loading States
On every screen that calls the backend, while waiting for response:
- Enroll, Authenticate, Verify, QC, History
- Expected: grey shimmer placeholder cards animate while loading
- No blank white space, no spinner-only screens

---

#### T4.10 — Offline / Error States
Turn off the backend server (Ctrl+C), then:
- Try to enroll → offline card appears with wifi-off icon, "Cannot reach server", "Check Settings → Server URL", Retry button
- Tap Retry → tries again (fails again since server is off)
- Restart server → tap Retry → works normally
- Test this on: Enroll, Authenticate, Verify, QC, History

---

#### T4.11 — Haptic Feedback
- Successful authentication → strong vibration (heavyImpact)
- Failed authentication → short buzz (vibrate)
- Successful verify → strong vibration
- Failed verify → short buzz
- Gesture liveness pass → strong vibration

---

#### T4.12 — Auto-Capture Behaviour
- Open any screen with the camera widget
- Switch to AUTO mode (default)
- Hold a clear fingerprint in the oval
- Watch the quality bar fill up and the 3 dots fill one by one
- Camera should auto-trigger without tapping anything
- Switch to MANUAL mode — auto-trigger stops, Capture button appears
- Toggle torch ON/OFF — flash activates

---

---

## Part 3 — Pending Features: Your Role

You have two responsibilities here:

1. If a feature is missing and **you can write it** — write it, test it, raise a PR to `develop`
2. If a feature is missing and **you cannot write it** — message the assigned person, give them a 2-day deadline, and track it

---

### P1 — QC Tool Tab 1: Image Quality ❌ MISSING

**Owner:** Ashish  
**File:** `backend/qctool/app.py` — inside the `with tab1:` block  
**What it should do:** Upload fingerprint → call `/quality_check` → show blur score, brightness, glare with green/red indicators

**Your action — message Ashish today:**

> "Ashish — QC Tool Tab 1 (Image Quality) is still an empty placeholder in backend/qctool/app.py. It needs to call /quality_check and show blur/brightness/glare results with colour indicators. Please complete this and raise a PR to develop within 2 days."

**If Ashish does not respond in 2 days — implement it yourself.** It is a Streamlit Python task, no ML knowledge needed. Spec:

```python
# backend/qctool/app.py — inside "with tab1:" block
# Follow the exact same pattern as render_readiness_tab() in the same file

def render_quality_tab(base_url: str):
    # 1. File uploader for fingerprint image
    # 2. Button: "Run quality check"
    # 3. POST uploaded image to /quality_check
    # 4. Show passed/failed badge (green if passed, red if failed)
    # 5. Show blur_score — green if > 50, red if < 50
    # 6. Show brightness — green if 50-210, red otherwise
    # 7. Show glare — red "Detected" or green "None"
    # 8. Show guidance string from response
    # 9. Show raw JSON in st.expander
```

Then in `main()` replace:
```python
with tab1:
    st.markdown("<div class='tab-spacer'></div>", unsafe_allow_html=True)
```
with:
```python
with tab1:
    render_quality_tab(base_url)
```

---

### P2 — QC Tool Tab 3: Contact vs Contactless Comparison ❌ MISSING

**Owner:** Ashish  
**File:** `backend/qctool/app.py` — inside the `with tab3:` block  
**What it should do:** Two uploaders (contact + contactless) → call `/compare_contact` → show similarity score, match count, side-by-side images

**Your action — message Ashish (combine with P1 message):**

> "Ashish — QC Tool Tab 3 (Contact vs Contactless) is also empty. It needs two image uploaders, calls /compare_contact, and shows similarity_score + matches side by side. Please complete both Tab 1 and Tab 3 in one PR within 2 days."

**If Ashish does not respond in 2 days — implement it yourself.** Spec:

```python
# backend/qctool/app.py — inside "with tab3:" block

def render_comparison_tab(base_url: str):
    # 1. Two file uploaders side by side using st.columns
    #    col1: contact image, col2: contactless image
    # 2. Button: "Run comparison"
    # 3. POST both files to /compare_contact
    #    files = {"contact": (...), "contactless": (...)}
    # 4. Show comparison.similarity_score as st.progress(score / 100)
    # 5. Show comparison.matches count
    # 6. Show both uploaded images side by side
    # 7. Show raw JSON in st.expander
```

Then in `main()` replace:
```python
with tab3:
    st.markdown("<div class='tab-spacer'></div>", unsafe_allow_html=True)
```
with:
```python
with tab3:
    render_comparison_tab(base_url)
```

---

### P3 — ISO Template Export: Simplified Header ⚠️ PARTIAL

**Owner:** Ashish  
**File:** `backend/app.py` → `export_iso_template()`  
**Issue:** Current header is 6 bytes (`FMR 20`). Full ISO 19794-4 requires a 28-byte header with capture equipment, image dimensions, resolution, and finger count fields.

**Your action — message Ashish:**

> "Ashish — export_iso_template() in backend/app.py uses a simplified 6-byte header. For UIDAI submission it should follow the full ISO 19794-4 format (28-byte header). Reference: https://www.iso.org/standard/50864.html — can you update this?"

**Do not attempt to fix this yourself** — it is a binary format spec task. Just track it.

---

### P4 — QcScreen Not in Router ⚠️ MINOR

**Owner:** Atharv  
**File:** `lib/router.dart`  
**Issue:** `QcScreen` is not registered as a named route — only reachable from HomeScreen directly.

**Your action — message Atharv:**

> "Atharv — QcScreen is not in router.dart. Should it have a /qc route? One-line fix if needed."

**You can fix this yourself** if Atharv confirms — it is one line in `lib/router.dart`:

```dart
GoRoute(path: '/qc', builder: (context, state) => const QcScreen()),
```

---

### P5 — `/liveness_gesture` Needs a Hand Photo (By Design)

**Owner:** Nandhini — this is not a bug  
**Note:** MediaPipe detects hand landmarks, not fingerprints. The endpoint needs a photo of a hand showing fingers. Document this clearly in your test report so the team knows what image to use when testing.



---

## Part 4 — How to Report Issues

When you find a bug or a test failure, raise it like this in the group chat or as a GitHub Issue:

```
🐛 BUG — [Screen/Endpoint]
What I did: <exact steps>
What I expected: <expected result>
What happened: <actual result>
Severity: Critical / High / Medium / Low
Tag: @Atharv / @Ashish / @Vignesh / @Nandhini / @Ishita
```

Example:
```
🐛 BUG — /readiness endpoint
What I did: curl -X POST /readiness with a blurry image
What I expected: readiness_score < 40, grade: Rejected
What happened: readiness_score: 72, grade: Good
Severity: High
Tag: @Nandhini
```

---

## Part 5 — Git Workflow

You only commit test reports and documentation. Never modify `lib/`, `backend/app.py`, or any source files.

```bash
# Every day before starting
git checkout develop
git pull origin develop
git checkout feature/raj-testing
git merge develop

# After writing your test report
git add RAJ_TEST_REPORT.md
git commit -m "test: API testing results — all 15 endpoints"
git push origin feature/raj-testing
```

Raise a PR to `develop` when your full test report is ready. Tag Atharv as reviewer.

---

## Part 6 — Test Report Template

Create a file called `RAJ_TEST_REPORT.md` in the repo root. Use this format:

```markdown
# Raj — Test Report
Date: <date>
Backend version: <git commit hash from `git log --oneline -1`>

## API Tests

| Test | Endpoint | Result | Notes |
|------|----------|--------|-------|
| T1.1 | GET /health | ✅ PASS | all models loaded |
| T1.2 | POST /quality_check | ✅ PASS | guidance correct |
| T1.3 | POST /enroll | ✅ PASS | 42 minutiae |
| ...  | ...          | ...     | ...   |

## App Tests

| Test | Screen | Result | Notes |
|------|--------|--------|-------|
| T4.1 | Splash | ✅ PASS | animation smooth |
| T4.2 | Settings | ✅ PASS | health check green |
| ...  | ...      | ...     | ...   |

## Benchmark

| Item | Result |
|------|--------|
| Script runs without crash | ✅ / ❌ |
| benchmark_results.csv generated | ✅ / ❌ |
| eer_plot.png generated | ✅ / ❌ |
| EER value | <value> at threshold <value> |

## QC Tool

| Tab | Result | Notes |
|-----|--------|-------|
| Tab 2 Readiness | ✅ PASS | score + chart shown |
| Tab 4 Contact | ✅ PASS | processed image shown |
| Tab 1 Image Quality | ❌ NOT IMPLEMENTED | Ashish pending |
| Tab 3 Comparison | ❌ NOT IMPLEMENTED | Ashish pending |

## Bugs Found

| # | Severity | Description | Assigned To | Status |
|---|----------|-------------|-------------|--------|
| 1 | High | ... | @Nandhini | Open |

## Summary

- Total API tests: 15 | Pass: _ | Fail: _
- Total App tests: 12 | Pass: _ | Fail: _
- Bugs raised: _
- Blockers: _
```

---

## Part 7 — Definition of Done (Your Tasks)

Your testing is complete when:

1. All 15 API endpoints tested with curl — results documented
2. `benchmark.py` runs successfully — CSV and plot generated
3. Streamlit QC Tool Tab 2 and Tab 4 tested — results documented
4. All 12 Flutter app test cases run on physical device or emulator
5. `RAJ_TEST_REPORT.md` filled out completely
6. All bugs raised in group chat / GitHub Issues with correct tags
7. PR raised to `develop` with test report
8. Atharv approves

---

## Quick Reference — Useful Commands

```bash
# Start backend
cd uidai_app/backend && source venv/bin/activate && bash start.sh

# Start QC tool
cd uidai_app/backend/qctool && streamlit run app.py

# Run benchmark
cd uidai_app/backend && python benchmark.py

# Flutter analyze
cd uidai_app && flutter analyze

# Build APK
cd uidai_app && flutter build apk --debug

# Install APK on device
adb install build/app/outputs/flutter-apk/app-debug.apk

# Find your laptop IP (Mac)
ipconfig getifaddr en0

# Find your laptop IP (Windows)
ipconfig

# Check git log
git log --oneline -5

# Health check
curl http://localhost:5001/health
```

---

*YellowSense Technologies · SITAA Cohort 1 · 2025*  
*Questions? Ask Atharv.*
