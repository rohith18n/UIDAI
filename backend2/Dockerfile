# cloud_app.py — templatization + matching only. Deliberately does NOT build the
# rest of backend/ into this image: no YOLO/liveness/U2Net/Zero-DCE weights, no
# torchvision/ultralytics/tensorflow/mediapipe. Those are on-device-tier and never
# run here — see requirements-cloud.txt for the reasoning.

FROM python:3.10-slim

# opencv-python-headless still needs these even without GUI support.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libglib2.0-0 \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements-cloud.txt .
RUN pip install --no-cache-dir -r requirements-cloud.txt

# Application code — only what cloud_app.py actually imports.
COPY cloud_app.py .
COPY minutiae.py .
COPY slap_matching.py .
COPY matching.py .
COPY algorithms/ ./algorithms/

# The one model this service needs. The other four (YOLO x2, liveness, U2Net,
# Zero-DCE) are on-device-tier and are never copied into this image.
COPY best_f1.pth .

# SQLite files live on a mounted volume, not baked into the image — persists
# across container restarts/redeploys. Mount a host directory here at run time:
#   docker run -v /srv/sitaa-cloud-data:/data ...
ENV DATABASE=/data/uidai.db
ENV SLAP_DB=/data/slap.db
VOLUME ["/data"]

ENV PORT=8080
EXPOSE 8080

# gunicorn, not Flask's dev server. One worker per CPU core is the usual rule of
# thumb; 2 is a safe default for the small VM this is meant to run on — tune via
# GUNICORN_WORKERS if the box is bigger. --timeout is a safety ceiling (the
# acceptance gate wants actual matching under 5s; this just stops a hung request
# from blocking a worker forever).
CMD gunicorn --bind 0.0.0.0:${PORT} \
    --workers ${GUNICORN_WORKERS:-2} \
    --timeout 60 \
    cloud_app:app
