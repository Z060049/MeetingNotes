#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/AutoScribe.app"
WAIT_SECONDS="${1:-90}"

if [ ! -d "$APP_DIR" ]; then
    echo "AutoScribe.app is missing. Run ./scripts/build-dev-app.sh first."
    exit 1
fi

if pgrep -f "$APP_DIR/Contents/MacOS/AutoScribe" >/dev/null; then
    echo "AutoScribe is already running. Quit it before this test."
    exit 1
fi

open -n "$APP_DIR"
sleep 2

PID="$(pgrep -f "$APP_DIR/Contents/MacOS/AutoScribe")"
echo "AutoScribe started with pid $PID; checking for ${WAIT_SECONDS}s."

for ((elapsed = 0; elapsed < WAIT_SECONDS; elapsed += 5)); do
    sleep 5
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FAIL: AutoScribe exited after approximately $((elapsed + 5))s."
        exit 1
    fi
done

echo "PASS: AutoScribe remained alive for ${WAIT_SECONDS}s."
osascript -e 'tell application id "com.autoscribe.dev" to quit'
sleep 2

if kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: AutoScribe did not quit cleanly."
    exit 1
fi

echo "PASS: AutoScribe quit cleanly."
