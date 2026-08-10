# YellowSense UIDAI — Team Onboarding & Work Guide

> Read this **fully and in order** before touching any code.  
> This tells you exactly how to set up, build the app, install it on your phone, and start working.

---

## Who Does What (Quick Reference)

| Person | Works On | Does NOT touch |
|--------|----------|----------------|
| **Atharv** | Flutter UI + CI/CD + GitHub | — |
| **Ishita** | Flutter UI + wiring backend into screens | — |
| **Ashish** | `backend/app.py` + `backend/qctool/` (Streamlit) | Flutter |
| **Vignesh** | `backend/app.py` + `backend/qctool/` (Streamlit) | Flutter |
| **Nandhini** | `backend/app.py` only | Flutter, Streamlit |

---

## Part 1 — Install Required Tools

### Everyone needs

| Tool | Download |
|------|----------|
| **Git** | https://git-scm.com/downloads |
| **VS Code** | https://code.visualstudio.com |

---

### Atharv + Ishita also need (Flutter)

#### 1. Install Flutter SDK 3.41.4

**Mac:**
```bash
# Download Flutter
cd ~/development
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.41.4-stable.zip
unzip flutter_macos_arm64_3.41.4-stable.zip

# Add to PATH — add this line to ~/.zshrc
export PATH="$PATH:$HOME/development/flutter/bin"

# Reload terminal
source ~/.zshrc

# Verify
flutter --version
```

**Windows:**
1. Download Flutter ZIP from https://docs.flutter.dev/get-started/install/windows
2. Extract to `C:\flutter`
3. Open **System Properties → Environment Variables → Path → Edit → New**
4. Add `C:\flutter\bin`
5. Open a new terminal and run `flutter --version`

#### 2. Install Android Studio
- Download from https://developer.android.com/studio
- Open Android Studio → **SDK Manager** → install **Android SDK 34**
- Open **Device Manager → Create Virtual Device → Pixel 6 → API 34 → Finish**

#### 3. Verify Flutter sees everything
```bash
flutter doctor
```
Fix any issues it shows. You need at minimum:
- ✅ Flutter
- ✅ Android toolchain
- ✅ Android Studio

---

### Ashish + Vignesh + Nandhini also need (Python)

**Mac:**
```bash
brew install python@3.11
python3.11 --version   # should print Python 3.11.x
```

**Windows:**
1. Download Python 3.11 from https://www.python.org/downloads/release/python-3110/
2. During install — **check "Add Python to PATH"**
3. Open a new terminal and run `python --version`

---

## Part 2 — Clone the Repo & Get Model Files

### Step 1 — Clone

```bash
git clone https://github.com/ish1416/UIDAI.git
cd UIDAI
```

You will see this structure:
```
UIDAI/
├── lib/                ← Flutter app source (Atharv + Ishita)
├── android/
├── pubspec.yaml
├── backend/            ← Flask server (Ashish + Vignesh + Nandhini)
│   ├── app.py
│   ├── requirements.txt
│   ├── start.sh
│   └── qctool/
├── .github/
│   └── workflows/
│       └── ci.yml
├── TEAM_STRATEGY.md
└── TEAM_ONBOARDING.md  ← this file
```

---

### Step 2 — Get the Model Files

Model files are too large for Git. **Atharv will share them via Google Drive.**  
Download all of them and place them inside the `backend/` folder.

| File | Size |
|------|------|
| `best-new.pt` | 6.4 MB |
| `best_f1.pth` | 100 MB |
| `liveness_model_v3.pt` | 10 MB |
| `u2net_320x320_float32.tflite` | 4 MB |
| `zero_dce_model.h5` | 966 KB |
| `bright_spot_detection.pt` | 21 MB |

After placing them, your `backend/` folder should look like:
```
backend/
├── app.py
├── requirements.txt
├── start.sh
├── best-new.pt
├── best_f1.pth
├── liveness_model_v3.pt
├── u2net_320x320_float32.tflite
├── zero_dce_model.h5
└── bright_spot_detection.pt
```

---

## Part 3 — Backend Setup & Running (Everyone does this)

Everyone on the team needs the backend running to test the app — even Atharv and Ishita.

### Step 1 — Create Python virtual environment

**Mac/Linux:**
```bash
cd UIDAI/backend
python3.11 -m venv venv
source venv/bin/activate
```

**Windows:**
```powershell
cd UIDAI\backend
python -m venv venv
venv\Scripts\activate
```

> ⚠️ You must run the activate command **every time** you open a new terminal before working on the backend.

---

### Step 2 — Install dependencies

**Mac (Apple Silicon — M1/M2/M3):**
```bash
pip install -r requirements.txt
pip install tensorflow-macos==2.16.2 tensorflow-metal==1.2.0
```

**Mac (Intel) / Windows / Linux:**
```bash
pip install -r requirements.txt
```

> If tensorflow fails on Windows, run: `pip install tensorflow-cpu`

---

### Step 3 — Verify installation

```bash
python -c "import flask, torch, cv2, ultralytics, tensorflow; print('ALL OK')"
```

You should see `ALL OK`. If any module fails, run `pip install <that-module>` again.

---

### Step 4 — Start the backend server

**Mac/Linux:**
```bash
cd UIDAI/backend
source venv/bin/activate
bash start.sh
```

**Windows:**
```powershell
cd UIDAI\backend
venv\Scripts\activate
python app.py
```

You should see this output — wait for all models to load:
```
✓ U2Net loaded
✓ Zero-DCE loaded
✓ MinutiaeNet loaded
✓ Liveness loaded (threshold=0.3)
✓ Bright-spot detector loaded
* Running on http://0.0.0.0:5001
```

---

### Step 5 — Test the server is working

Open a **new terminal** (keep the server running in the first one) and run:

```bash
curl http://localhost:5001/health
```

You should see:
```json
{
  "status": "ok",
  "liveness_available": true,
  "minutiae_available": true,
  "brightspot_available": true
}
```

If you see this — your backend is fully working. ✅

---

### Step 6 — Find your laptop's IP address

You need this to connect the phone app to your backend.

**Mac:**
```bash
ipconfig getifaddr en0
```

**Windows:**
```powershell
ipconfig
```
Look for **IPv4 Address** under your WiFi adapter. It will look like `192.168.x.x`.

> Write this IP down — you will need it in Part 5.

---

## Part 4 — Build & Install the App on Your Phone

### Who does this

**Everyone** should install the app on their phone so they can test their work.

---

### Step 1 — Install Flutter dependencies

```bash
cd UIDAI
flutter pub get
```

---

### Step 2 — Build the APK

```bash
flutter build apk --debug
```

This takes 2–5 minutes the first time. You will see:
```
Running Gradle task 'assembleDebug'...
✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

---

### Step 3 — Find the APK file

The APK is at:
```
UIDAI/build/app/outputs/flutter-apk/app-debug.apk
```

**On Mac — open the folder in Finder:**
```bash
open build/app/outputs/flutter-apk/
```

**On Windows — open in Explorer:**
```powershell
explorer build\app\outputs\flutter-apk\
```

You will see `app-debug.apk` in that folder.

---

### Step 4 — Transfer APK to your phone

**Option A — USB cable (fastest):**
1. Connect phone to laptop via USB
2. On phone — tap the notification "Charging via USB" → select **File Transfer**
3. On Mac: use Android File Transfer app (https://www.android.com/filetransfer/)
4. On Windows: open File Explorer → your phone appears as a drive
5. Copy `app-debug.apk` to your phone's Downloads folder

**Option B — WhatsApp/Telegram (easiest):**
1. Send `app-debug.apk` to yourself on WhatsApp or Telegram
2. Open it on your phone and download

**Option C — Google Drive:**
1. Upload `app-debug.apk` to Google Drive
2. Open Google Drive on your phone and download it

---

### Step 5 — Install the APK on your phone

1. On your phone, open **Files** app → go to Downloads
2. Tap `app-debug.apk`
3. If you see **"Install blocked"** → go to Settings → Security → enable **"Install from unknown sources"** or **"Install unknown apps"** for your Files app
4. Tap **Install**
5. Tap **Open**

You should see the YellowSense splash screen. ✅

---

## Part 5 — Connect the App to the Backend

> Your phone and laptop **must be on the same WiFi network** for this to work.

1. Make sure the backend server is running on your laptop (Part 3, Step 4)
2. Open the app on your phone
3. Tap **Settings** (gear icon on home screen)
4. In the **Server URL** field, enter:
   ```
   http://192.168.x.x:5001
   ```
   Replace `192.168.x.x` with your laptop's actual IP from Part 3 Step 6
5. Tap **Save URL**
6. Tap **Check Health**

You should see **"Server Online"** with green checkmark. ✅

If you see "Unreachable":
- Make sure phone and laptop are on the **same WiFi** (not one on mobile data)
- Make sure the backend server is still running in your terminal
- Double-check the IP address — run `ipconfig getifaddr en0` again on Mac

---

## Part 6 — Running the App During Development (Atharv + Ishita only)

For Flutter development, instead of building an APK every time, you can run directly on a connected device with hot reload.

### Option A — Physical phone with USB

1. On your Android phone:
   - Go to **Settings → About Phone**
   - Tap **Build Number** 7 times until you see "You are now a developer"
   - Go back to **Settings → Developer Options**
   - Enable **USB Debugging**

2. Connect phone to laptop via USB. On phone, tap **Allow** when asked to trust the computer.

3. Run:
```bash
cd UIDAI
flutter devices        # should show your phone
flutter run            # builds and installs on phone
```

4. While the app is running:
   - Press `r` in terminal → **hot reload** (instant UI update)
   - Press `R` → **hot restart** (full restart)
   - Press `q` → quit

### Option B — Android Emulator

1. Open Android Studio → **Device Manager** → Start the Pixel 6 emulator
2. Run:
```bash
flutter run
```
Flutter will automatically detect the emulator.

> For emulator, use `http://10.0.2.2:5001` as the server URL in Settings (not your laptop IP).

---

## Part 7 — Git Workflow (How to Actually Work)

### The Branch Rules

```
main        ← NEVER commit here. Only Atharv merges here at end of sprint.
develop     ← NEVER commit here. Merge your feature branch here via PR.
feature/your-name-task  ← YOUR branch. This is where you work every day.
```

### Day 1 — Create your branch (do this once)

```bash
git checkout develop
git pull origin develop
git checkout -b feature/your-name-task
```

Your branch names:
- Atharv → `feature/atharv-autocapture`
- Ishita → `feature/ishita-ui`
- Ashish → `feature/ashish-iso-qctool`
- Vignesh → `feature/vignesh-roi-benchmark`
- Nandhini → `feature/nandhini-backend`

---

### Every day — before you start coding

```bash
git checkout develop
git pull origin develop
git checkout feature/your-name-task
git merge develop
```

---

### While coding — save your work often

```bash
git add .
git commit -m "feat: add /readiness endpoint with 0-100 score"
git push origin feature/your-name-task
```

---

### When your task is done — raise a Pull Request

1. Go to `github.com/ish1416/UIDAI`
2. Click **"Compare & pull request"**
3. Set base branch to `develop` ← important, NOT main
4. Write what you built in the description
5. Tag **Atharv** as reviewer
6. Wait for CI ✅ and Atharv's approval
7. Merge

---

### Commit message format

```
feat: add /readiness endpoint returning 0-100 score
feat: add /check_roi endpoint with move left/right guidance
fix: blur threshold lowered for fingerprint images
fix: server URL not saving on settings screen
```

---

## Part 8 — Your Specific Tasks

---

### 👤 Nandhini — Backend only

**Branch:** `feature/nandhini-backend`  
**Files:** `backend/app.py` only

#### Task 1 — `/readiness` endpoint

Open `backend/app.py`. Add just before `if __name__ == "__main__":`:

```python
@app.route("/readiness", methods=["POST"])
def readiness():
    # 1. Accept image file, save to uploads/
    # 2. Run quality_gate() → blur, brightness, glare
    # 3. Run detect_and_crop() + preprocess_fingerprint() + detect_minutiae()
    # 4. Normalize each metric 0-1
    # 5. score = blur_norm*30 + brightness_norm*25 + glare_norm*20 + minutiae_norm*25
    # 6. grade: 80-100=Excellent, 60-79=Good, 40-59=Marginal, 0-39=Rejected
    # 7. Return score + grade + breakdown
```

Test:
```bash
curl -X POST http://localhost:5001/readiness \
  -F "image=@uploads/any_fingerprint.jpg"
```

#### Task 2 — `/liveness_gesture` endpoint

```bash
pip install mediapipe
```

```python
@app.route("/liveness_gesture", methods=["POST"])
def liveness_gesture():
    # 1. Accept image + expected_count (1-5)
    # 2. Run MediaPipe hand detection
    # 3. Count extended fingers
    # 4. Return detected_count, expected_count, passed (bool)
```

---

### 👤 Vignesh — Backend + Streamlit

**Branch:** `feature/vignesh-roi-benchmark`  
**Files:** `backend/app.py` + `backend/qctool/app.py`

#### Task 1 — `/check_roi` endpoint

```python
@app.route("/check_roi", methods=["POST"])
def check_roi():
    # 1. Accept image
    # 2. Run YOLO → get bbox → compute center
    # 3. Compare to image center
    # 4. Return in_roi, offset_x, offset_y, guidance string
    # guidance: "Move left/right/up/down" or "Good — finger centered"
```

#### Task 2 — `backend/benchmark.py`

```bash
# New file — run standalone
python benchmark.py
# Outputs: benchmark_results.csv + eer_plot.png
```

#### Task 3 — QC Tool Tab 2 + Tab 4

In `backend/qctool/app.py`:
- Tab 2: upload image → call `/readiness` → show score + bar chart
- Tab 4: upload contact image → call `/process_contact` → show result

---

### 👤 Ashish — Backend + Streamlit

**Branch:** `feature/ashish-iso-qctool`  
**Files:** `backend/app.py` + `backend/qctool/app.py`

#### Task 1 — Contact preprocessing

Port `preprocess_contact_fingerprint()` from `contactless_attendance/backend/app.py`:
```python
def preprocess_contact_fingerprint(image_bgr):
    # Otsu → CLAHE → Gabor (8 orientations) → resize 256x256

@app.route("/process_contact", methods=["POST"])
def process_contact():
    # Accept image → preprocess → return base64
```

#### Task 2 — ISO 19794-4 template export

```python
def export_iso_template(minutiae, image_width, image_height):
    # Build ISO binary record
    # Return bytes

@app.route("/export_template", methods=["POST"])
def export_template():
    # Accept uid + batch → fetch from DB → export → return base64
```

Reference: https://www.iso.org/standard/50864.html

#### Task 3 — QC Tool Tab 1 + Tab 3

In `backend/qctool/app.py`:
- Tab 1: upload image → call `/quality_check` → show blur/brightness/glare
- Tab 3: upload contact + contactless → compare SSIM/ORB/SIFT side by side

Start QC tool:
```bash
cd backend/qctool
pip install streamlit scikit-image scikit-learn
streamlit run app.py
# Opens at http://localhost:8501
```

---

### 👤 Ishita — Flutter UI

**Branch:** `feature/ishita-ui`  
**Files:** `lib/` only

#### Task 1 — Shimmer loading states

Add to `pubspec.yaml` under dependencies:
```yaml
shimmer: ^3.0.0
```

Run `flutter pub get`.

On every screen while `_loading == true`, show shimmer instead of blank:
```dart
if (_loading)
  Shimmer.fromColors(
    baseColor: YS.stroke,
    highlightColor: YS.cardAlt,
    child: Container(height: 80,
      decoration: BoxDecoration(color: YS.card,
        borderRadius: BorderRadius.circular(14))),
  )
```

Files: `enroll_screen.dart`, `authenticate_screen.dart`, `screens.dart`

#### Task 2 — Server offline error state

On every screen, catch connection errors and show:
```dart
Column(children: [
  Icon(Icons.wifi_off_rounded, color: YS.inkLight, size: 48),
  Text('Cannot reach server', style: YS.label(14, color: YS.inkMid)),
  Text('Go to Settings and check Server URL',
      style: YS.label(12, color: YS.inkLight)),
  ElevatedButton(onPressed: _retry, child: Text('Retry')),
])
```

#### Task 3 — Wire readiness score into QC screen

After Nandhini finishes `/readiness`, update `QcScreen` in `screens.dart` to show the 0–100 score with grade badge.

#### Task 4 — Gesture liveness screen

After Nandhini finishes `/liveness_gesture`, create `lib/screens/gesture_liveness_screen.dart` — show finger count challenge, use front camera, show pass/fail.

---

### 👤 Atharv — Flutter + GitHub

**Branch:** `feature/atharv-autocapture`  
**Files:** `lib/widgets/fingerprint_camera_widget.dart`

#### Task 1 — GitHub setup

```bash
git clone https://github.com/ish1416/UIDAI.git
cd UIDAI
git fetch --all
git checkout develop
```

On GitHub:
- Settings → Collaborators → add everyone
- Settings → Branches → protect `main`:
  - ✅ Require pull request before merging
  - ✅ Require status checks (Flutter CI)
  - ✅ Require 1 approval

> If branch protection is greyed out, make the repo **public**: Settings → General → Change visibility → Public

#### Task 2 — Auto-capture

Add to `_FingerprintCameraWidgetState`:
```dart
Timer? _qualityTimer;
String _guidance = 'Place finger inside oval';
int _passCount = 0;

void _startQualityPolling() {
  _qualityTimer = Timer.periodic(Duration(milliseconds: 600), (_) async {
    if (!_live || _ctrl == null) return;
    // Capture frame → POST to /quality_check → update _guidance
    // If passed 3 consecutive times → call _capture()
  });
}
```

#### Task 3 — ROI guidance

After Vignesh finishes `/check_roi`, add to the polling loop:
- Show "Move left / right / up / down" on viewfinder
- Only auto-capture when quality AND ROI both pass

---

## Part 9 — Testing Before Raising a PR

### Backend (Ashish · Vignesh · Nandhini)

Always test with curl before raising a PR:

```bash
# Health check — make sure nothing is broken
curl http://localhost:5001/health

# Test your new endpoint
curl -X POST http://localhost:5001/readiness \
  -F "image=@uploads/any_fingerprint.jpg"

curl -X POST http://localhost:5001/check_roi \
  -F "image=@uploads/any_fingerprint.jpg"

curl -X POST http://localhost:5001/process_contact \
  -F "image=@uploads/any_fingerprint.jpg"

curl -X POST http://localhost:5001/export_template \
  -F "uid=test123" -F "batch=BATCH_A"

curl -X POST http://localhost:5001/liveness_gesture \
  -F "image=@uploads/any_fingerprint.jpg" \
  -F "expected_count=3"
```

### Flutter (Atharv · Ishita)

```bash
cd UIDAI
flutter analyze        # must show 0 errors
flutter build apk --debug  # must succeed
```

Then install the new APK on your phone and test the feature manually.

---

## Part 10 — Common Issues & Fixes

| Problem | Fix |
|---------|-----|
| `No module named X` | Run `source venv/bin/activate` then `pip install X` |
| `flutter: command not found` | Add Flutter bin to PATH, restart terminal |
| `No devices found` | Enable USB Debugging on phone, reconnect USB |
| `Server unreachable` in app | Check same WiFi, check server is running, verify IP in Settings |
| `Install blocked` on phone | Settings → Security → enable Install unknown apps |
| `Merge conflict` | Open file in VS Code, keep correct version, delete `<<<<` markers, `git add . && git commit` |
| Backend crashes on startup | Check all model files are in `backend/`, check venv is activated |
| `tensorflow` install fails on Windows | Use `pip install tensorflow-cpu` instead |

---

## Part 11 — Daily Standup

Post in the group chat every day:

```
✅ Done yesterday:
🔨 Doing today:
❌ Blocked by:
```

---

*YellowSense Technologies · SITAA Cohort 1 · 2025 · Questions? Ask Atharv.*
