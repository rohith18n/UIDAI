#!/bin/bash
cd "$(dirname "$0")"
if [ -d "venv" ]; then
  source venv/bin/activate
fi
PORT="${PORT:-5010}" python3 slap_app.py
