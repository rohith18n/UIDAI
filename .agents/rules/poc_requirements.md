# UIDAI Contactless Fingerprint Authentication SDK — PoC Specification Rules

## Core Architecture & Performance Budget (§2.2)

1. **On-Device Stage (Mandatory — Mobile Flutter App / SDK)**:
   - FP-01: Auto & Manual Camera Capture with real-time finger detection guidance.
   - FP-02: On-device Basic Liveness Check (anti-spoofing).
   - FP-03: On-device Quality Control (blur, brightness, glare, distance, focus rejection).
   - FP-04: Multi-Finger Capture (slap 4-finger and/or sequential single-finger).
   - FP-05: Preprocessing Pipeline (contactless image -> contact-equivalent fingerprint image).
   - FP-06: Segmented FIR Creation.
   - **Time Budget**: Under 5.0 seconds (Mandatory execution on-device).

2. **Cloud Stage (Python Backend — Ports 5002 & 5010)**:
   - FP-06: Standard FIR / FMR Template Generation (ISO/IEC 19794).
   - FP-07: Matching & Scoring Engine (1:1 Verification & 1:N Identification; 1:10 matching against the 10 enrolled fingers of a user).
   - **Time Budget**: Under 5.0 seconds.

## Mandatory Acceptance Gate (§2.5)
- **Matching Accuracy**: > 85% matching accuracy, user-wise, across at least 20 users on UIDAI for contactless-to-contactless (cL2cL).
- **End-to-End Latency**: On-device capture & FIR creation < 5 s; Cloud templatization & matching < 5 s.
- **Single APK**: Application must support both **Register (Enrolment)** and **Authenticate** within a single unified app flow.

## App Implementation & Logging Guidelines
- **Response Logging**: Keep structured `dev.log` (`dart:developer`) logging active for all HTTP API requests/responses (`API.SINGLE`, `API.SLAP`) and local SDK executions (`OFFLINE_SDK.RES`).
- **Offline Fallback Resilience**: Automatically fall back to on-device SDK processing (`processOffline`) if the Python server is offline (`Connection refused`) to ensure uninterrupted UI performance.
- **UI Layout Boundaries**: Ensure flex layouts (`Row`/`Column`) wrap text nodes in `Expanded`/`Flexible` with `TextOverflow.ellipsis` to prevent `RenderFlex` overflows on any mobile screen.
