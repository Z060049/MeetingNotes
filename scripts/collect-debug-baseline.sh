#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/AutoScribe.app"

cd "$ROOT_DIR"

echo "AutoScribe debug baseline"
echo "Captured: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

sw_vers
echo "Architecture: $(uname -m)"
echo "CPU: $(sysctl -n machdep.cpu.brand_string)"
echo "Memory bytes: $(sysctl -n hw.memsize)"
echo

swift --version
xcodebuild -version
echo "Developer directory: $(xcode-select -p)"
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "Metal Toolchain: installed"
else
    echo "Metal Toolchain: missing (install with: xcodebuild -downloadComponent MetalToolchain)"
fi
echo

echo "Commit: $(git rev-parse HEAD)"
echo "Branch: $(git branch --show-current)"
echo "Working tree:"
git status --short
shasum -a 256 Package.resolved
echo

if [ -d "$APP_DIR" ]; then
    echo "Bundle metadata:"
    plutil -p "$APP_DIR/Contents/Info.plist"
    echo
    echo "Code signature:"
    codesign -dv --verbose=2 "$APP_DIR" 2>&1
    echo
    echo "Entitlements:"
    codesign -d --entitlements - "$APP_DIR" 2>&1
else
    echo "Bundle not found at $APP_DIR"
fi

echo
echo "Persistent log: $HOME/Library/Logs/AutoScribe/AutoScribe.log"
echo "Recovery directory: $HOME/Library/Application Support/AutoScribe/Recording Recovery"
