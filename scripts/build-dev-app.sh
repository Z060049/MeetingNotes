#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
APP_DIR="$ROOT_DIR/.build/AutoScribe.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build

# ── Compile MLX Metal shaders ──────────────────────────────────────────────
# swift build doesn't compile .metal files; we do it here with xcrun metal.
# MLX looks for default.metallib inside mlx-swift_Cmlx.bundle/Contents/Resources/
METALLIB_CACHE="$ROOT_DIR/.build/mlx_metallib_cache"
METALLIB_OUT="$METALLIB_CACHE/default.metallib"
MLX_METAL_SRC="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"

if [ ! -f "$METALLIB_OUT" ]; then
  echo "Compiling MLX Metal shaders (first time, may take a minute)..."
  mkdir -p "$METALLIB_CACHE/air"
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  AIR_FILES=()
  for metal_file in "$MLX_METAL_SRC"/*.metal; do
    name=$(basename "$metal_file" .metal)
    air_file="$METALLIB_CACHE/air/${name}.air"
    xcrun -sdk macosx metal -c "$metal_file" -o "$air_file" \
      -target air64-apple-macos14.0 -O2 2>/dev/null || true
    [ -f "$air_file" ] && AIR_FILES+=("$air_file")
  done
  if [ ${#AIR_FILES[@]} -gt 0 ]; then
    xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$METALLIB_OUT"
    echo "MLX metallib compiled: $METALLIB_OUT"
  else
    echo "Warning: No Metal air files compiled, MLX GPU acceleration unavailable"
  fi
else
  echo "MLX metallib already compiled (cached)"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/AutoScribe" "$MACOS_DIR/AutoScribe"

# Bundle the MLX metallib so MLX can find it at runtime
if [ -f "$METALLIB_OUT" ]; then
  MLX_BUNDLE="$RESOURCES_DIR/mlx-swift_Cmlx.bundle"
  mkdir -p "$MLX_BUNDLE/Contents/Resources"
  cp "$METALLIB_OUT" "$MLX_BUNDLE/Contents/Resources/default.metallib"
  # Also place it next to binary (MLX searches there too)
  cp "$METALLIB_OUT" "$MACOS_DIR/default.metallib"
  echo "Bundled MLX metallib"
fi

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
    <string>AutoScribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.autoscribe.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AutoScribe</string>
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
    <string>AutoScribe records your microphone to create meeting transcripts and notes.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AutoScribe captures system audio to transcribe meeting participants and remote speakers.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AutoScribe may use screen capture as a temporary fallback for system audio recording during development.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - \
  --entitlements "$ROOT_DIR/scripts/dev.entitlements" \
  "$APP_DIR"

echo "Built $APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/codesign: /'
echo "Open it with: open \"$APP_DIR\""
