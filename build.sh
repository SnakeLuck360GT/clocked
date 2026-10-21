#!/bin/bash
# Builds build/Clocked.app
#   ./build.sh            build (downloads the phone-detection model once if missing)
#   ./build.sh dmg        also make build/Clocked-<version>.dmg to put online
#   SKIP_MODEL=1 ./build.sh   build without the model (falls back to Apple's built-in classifier)
# Signing for public release (needs the Apple Developer Program; otherwise the app is signed ad hoc):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh dmg
#   NOTARY_PROFILE=clocked ...   also notarize and staple the DMG (create the profile once with
#                                `xcrun notarytool store-credentials clocked`)
set -euo pipefail
cd "$(dirname "$0")"

# Command Line Tools ship several SDKs; use the one that matches this Swift compiler.
for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk "$(xcrun --show-sdk-path 2>/dev/null)"; do
  if [ -d "$sdk" ]; then export SDKROOT="$sdk"; break; fi
done

MODEL=Models/YOLOv3Tiny.mlmodelc
if [ ! -d "$MODEL" ] && [ "${SKIP_MODEL:-0}" != "1" ]; then
  echo "→ Fetching phone-detection model (one-time, ~35 MB, at build time only)…"
  mkdir -p Models
  tmp=$(mktemp -d)
  curl -fL --progress-bar -o "$tmp/YOLOv3Tiny.mlmodel" \
    https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel
  swiftc -sdk "$SDKROOT" Tools/compile-model.swift -o "$tmp/compile-model"
  "$tmp/compile-model" "$tmp/YOLOv3Tiny.mlmodel" "$MODEL"
  rm -rf "$tmp"
fi

echo "→ Compiling…"
# swiftc directly (not `swift build`): works even when SwiftPM in the Command Line Tools is broken.
mkdir -p .build/release
swiftc -O -swift-version 5 -sdk "$SDKROOT" -target arm64-apple-macos26.0 \
  -module-name Clocked -o .build/release/Clocked Sources/Clocked/*.swift Sources/Shared/*.swift
# The sync helper: the only part of Clocked with network access (outgoing HTTPS to Supabase, encrypted data only).
swiftc -O -swift-version 5 -sdk "$SDKROOT" -target arm64-apple-macos26.0 \
  -module-name ClockedSync -o .build/release/ClockedSync Sources/ClockedSync/*.swift Sources/Shared/*.swift

APP="build/Clocked.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clocked "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
[ -d "$MODEL" ] && cp -R "$MODEL" "$APP/Contents/Resources/"

XPC="$APP/Contents/XPCServices/ClockedSync.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp .build/release/ClockedSync "$XPC/Contents/MacOS/"
cp Support/ClockedSync-Info.plist "$XPC/Contents/Info.plist"

# Study-groups backend from supabase.env (git-ignored), if present. Read as plain KEY=value, never executed.
if [ -f supabase.env ]; then
  env_value() { grep -E "^[[:space:]]*$1[[:space:]]*=" supabase.env | tail -1 | cut -d= -f2- | tr -d '[:space:]"'"'"; }
  SB_URL=$(env_value SUPABASE_URL)
  SB_KEY=$(env_value SUPABASE_PUBLISHABLE_KEY)
  [ -z "$SB_KEY" ] && SB_KEY=$(env_value SUPABASE_ANON_KEY)
  if [[ ! "$SB_URL" =~ ^https://[A-Za-z0-9-]+\.supabase\.co/?$ ]]; then
    echo "✗ supabase.env: SUPABASE_URL must look like https://your-project.supabase.co" >&2; exit 1
  fi
  if [[ "$SB_KEY" == sb_secret_* ]] || { [[ "$SB_KEY" == eyJ* ]] && echo "$SB_KEY" | cut -d. -f2 | base64 -D 2>/dev/null | grep -q service_role; }; then
    echo "✗ supabase.env: that's a SECRET key. Use the publishable key (sb_publishable_…); a secret key bypasses all security." >&2; exit 1
  fi
  if [ -z "$SB_KEY" ]; then echo "✗ supabase.env: SUPABASE_PUBLISHABLE_KEY is empty" >&2; exit 1; fi
  /usr/libexec/PlistBuddy -c "Add :ClockedSupabaseURL string $SB_URL" -c "Add :ClockedSupabaseKey string $SB_KEY" "$APP/Contents/Info.plist"
  echo "→ Study groups: using $SB_URL from supabase.env as Clocked's database (off until each user turns on online features)"
fi

# Helper first, then the app around it. A Developer ID build also needs the hardened runtime and a timestamp.
IDENTITY="${SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_FLAGS+=(--options runtime --timestamp)
echo "→ Signing ($([ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "$IDENTITY"); sandboxed, only the sync helper may use the network)…"
codesign "${SIGN_FLAGS[@]}" --entitlements Support/ClockedSync.entitlements "$XPC"
codesign "${SIGN_FLAGS[@]}" --entitlements Support/Clocked.entitlements "$APP"

echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"
echo "  Run:     open \"$APP\""
echo "  Install: cp -R \"$APP\" /Applications/"

if [ "${1:-}" = "dmg" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  DMG="build/Clocked-$VERSION.dmg"
  echo "→ Making ${DMG}…"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"   # drag-to-install
  rm -f "$DMG"
  hdiutil create -quiet -volname "Clocked" -srcfolder "$STAGE" -fs HFS+ -format ULMO -ov "$DMG"
  rm -rf "$STAGE"
  if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      echo "→ Notarizing (a few minutes)…"
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
  else
    echo "  Note: signed ad hoc, not notarized. People who download it must open it once via"
    echo "        System Settings → Privacy & Security → Open Anyway."
  fi
  echo "✓ Built $DMG ($(du -h "$DMG" | cut -f1))"
fi
