#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/build"
APP_DIR="$OUTPUT_DIR/MeetingNotes.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/MeetingNotes" "$MACOS_DIR/MeetingNotes"

if [ -f "$ROOT_DIR/.env" ]; then
  cp "$ROOT_DIR/.env" "$RESOURCES_DIR/.env"
  echo "Bundled .env into app resources"
fi

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  echo "Bundled AppIcon.icns into app resources"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MeetingNotes</string>
    <key>CFBundleIdentifier</key>
    <string>com.meetingnotes.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MeetingNotes</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MeetingNotes records your microphone to create meeting transcripts.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MeetingNotes captures system audio to transcribe meeting participants and remote speakers. Screen video is not saved.</string>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity so TCC permissions (Microphone, Screen
# Recording) survive rebuilds. Ad-hoc signing changes the cdhash every build,
# which invalidates granted permissions and re-triggers the onboarding loop.
# Create the identity once with ./scripts/create-dev-signing-identity.sh
SIGNING_IDENTITY="${MEETINGNOTES_SIGNING_IDENTITY:-MeetingNotes Dev Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGNING_IDENTITY"; then
  echo "Signing with stable identity: $SIGNING_IDENTITY"
  codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/scripts/dev.entitlements" \
    "$APP_DIR"
else
  echo "WARNING: stable signing identity '$SIGNING_IDENTITY' not found; falling back to ad-hoc."
  echo "         TCC permissions will reset on every rebuild and onboarding may loop."
  echo "         Run ./scripts/create-dev-signing-identity.sh once to fix this permanently."
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/scripts/dev.entitlements" \
    "$APP_DIR"
fi

echo "Built $APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/codesign: /'
echo "Open it with: open \"$APP_DIR\""
