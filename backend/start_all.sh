#!/bin/bash
cd "$(dirname "$0")"
if [ -d "venv" ]; then
  source venv/bin/activate
fi

echo "Starting Single-Finger Backend on port 5002..."
PORT=5002 python3 app.py &
PID_SINGLE=$!

echo "Starting Slap (Multi-Finger) Backend on port 5010..."
PORT=5010 python3 slap_app.py &
PID_SLAP=$!

echo "Both backends started. (Single PID: $PID_SINGLE, Slap PID: $PID_SLAP)"
echo "Press Ctrl+C to stop both."

trap "kill $PID_SINGLE $PID_SLAP 2>/dev/null" EXIT
wait
