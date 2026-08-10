# UIDAI Unified App (Single + Slap)

This branch contains a single Flutter app that supports:

- Single-finger capture/enroll/auth/verify (backend port 5002)
- Slap (4-finger) capture/enroll/auth/verify (backend port 5010)

The two backends keep separate databases:

- single: `uidai.db`
- slap: `slap.db`

## Prerequisites

- Flutter SDK (stable)
- Android SDK / adb
- Python 3.10+ (recommended) for the backends

## Run Backends (local)

From `backend/`:

```bash
cd backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
PORT=5002 python app.py
```

In another terminal:

```bash
cd backend
source venv/bin/activate
PORT=5010 python slap_app.py
```

Health checks:

- http://127.0.0.1:5002/health
- http://127.0.0.1:5010/health

## Run Flutter App

```bash
flutter pub get
flutter run
```

In the app:

- Settings → set backend URLs
  - Single: `http://<YOUR_LAN_IP>:5002`
  - Slap: `http://<YOUR_LAN_IP>:5010`

## Models (Large Files)

The backend model files are intentionally not committed to git.
You must place them under:

- `backend/models/`

Expected model files:

- `best-new.pt`
- `bright_spot_detection.pt`
- `best_f1.pth`
- `liveness_model_v3.pt`
- `zero_dce_model.h5`
- `u2net_320x320_float32.tflite`
- `best_float32.tflite`

## Repo Branches (High Level)
- `feature/uidai-unified` (this branch): unified Flutter app + dual backends
- `feature/uidai-app`: original single-finger app
- `feature/slap-preprocessing`: original slap preprocessing repo snapshot (contains `UIDAI-IITB-CONTACTLESS-preprocessing/`)

## New Developer Onboarding (Suggested Checklist)
- Build and run both backends locally and confirm `/health` works on 5002 and 5010.
- Run the Flutter app and confirm Settings → Health checks pass for both URLs.
- Read these key files:
  - `lib/widgets/fingerprint_camera_widget.dart` (poll loop + auto-capture)
  - `backend/app.py` (single pipeline + models)
  - `backend/slap_app.py` + `backend/slap_core.py` (slap pipeline + matching aggregation)
  - `lib/services/api_service.dart` (dual-server API wiring)

## Target Architecture Goal (Offline Under 5s)
Goal: run all steps on-device (offline) under 5 seconds end-to-end, except:
- Template generation and matching remain on cloud/backend

Steps that should move on-device first:
- Finger detection + ROI crop
- Quality checks (blur/brightness/glare)
- Segmentation + preprocessing (contrast/enhancement)
- Liveness (if feasible on-device)
