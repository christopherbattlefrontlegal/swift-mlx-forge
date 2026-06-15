#!/usr/bin/env bash
# Forge — assemble a runnable local developer .app from the release build.
#
# Default output is intentionally unsandboxed so stdio MCP servers can launch
# node/npx/uv/python commands like Claude Desktop. Use --mas-sandbox when you
# specifically want to test the Mac App Store sandbox profile.
#
#   ./scripts/build-app.sh                  # build + bundle into ./Forge.app
#   ./scripts/build-app.sh /Applications    # also install a copy there
#   ./scripts/build-app.sh --mas-sandbox    # App Store sandbox test build
#
# This script runs the matching security check before packaging.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ENT="$ROOT/MacAppStore/Forge.entitlements"
EXE="$ROOT/.build/arm64-apple-macosx/release/mlx-forge"
METALLIB="$ROOT/.build/arm64-apple-macosx/release/mlx.metallib"
# llama.cpp (GGUF) backend, packaged as a framework by LLM.swift. The Forge binary
# links it as @rpath/llama.framework/...; if it's not bundled, dyld aborts the app
# at launch ("Library not loaded: @rpath/llama.framework"). Must be copied into
# Contents/Frameworks and signed inside-out.
LLAMA_FW="$ROOT/.build/arm64-apple-macosx/release/llama.framework"
APP="$ROOT/Forge.app"
INSTALL_DEST=""
SANDBOX=0

for arg in "$@"; do
  case "$arg" in
    /Applications)
      INSTALL_DEST="/Applications"
      ;;
    --mas-sandbox|--sandbox)
      SANDBOX=1
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: ./scripts/build-app.sh [--mas-sandbox] [/Applications]"
      exit 2
      ;;
  esac
done

echo "── security gate ─────────────────────────────────────"
if [[ "$SANDBOX" -eq 1 ]]; then
  "$ROOT/scripts/security-check.sh" --mas || { echo "Refusing to package: MAS security check failed."; exit 1; }
else
  "$ROOT/scripts/security-check.sh" --developer || { echo "Refusing to package: developer security check failed."; exit 1; }
fi

echo "── build (release) ───────────────────────────────────"
# IMPORTANT: build the PRODUCT, not the target. `--target` compiles object files
# but does NOT link the executable, so the binary silently goes stale while every
# build still reports "complete". `--product` forces the link step every time.
swift build -c release --product mlx-forge

# mlx.metallib is built by a SEPARATE script (not swift build). Without it MLX
# crashes on launch ("Failed to load the default metallib"). Build it if missing
# and refuse to ship a bundle that would crash.
if [[ ! -f "$METALLIB" ]]; then
  echo "mlx.metallib missing — building Metal kernels…"
  "$ROOT/scripts/build-metallib.sh" release
fi

[[ -f "$EXE" ]] || { echo "Missing build product: $EXE"; exit 1; }
if [[ "$SANDBOX" -eq 1 ]]; then
  [[ -f "$ENT" ]] || { echo "Missing entitlements: $ENT"; exit 1; }
fi
[[ -f "$METALLIB" ]] || { echo "FATAL: mlx.metallib could not be built — app would crash on launch. Aborting."; exit 1; }
[[ -d "$LLAMA_FW" ]] || { echo "FATAL: llama.framework missing ($LLAMA_FW) — GGUF backend would abort the app at launch. Aborting."; exit 1; }

echo "── assemble bundle ───────────────────────────────────"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$EXE" "$APP/Contents/MacOS/Forge"
cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
# Bundle the llama.cpp framework and make the binary look for it in Frameworks.
# The release binary ships with rpath @loader_path only; add the standard
# @executable_path/../Frameworks so dyld resolves @rpath/llama.framework here.
cp -R "$LLAMA_FW" "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Forge"
# App icon (built by scripts/make-icon.swift → iconutil). Optional but required
# for the Mac App Store; if present, it's bundled and referenced in Info.plist.
ICON_PLIST=""
if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Forge</string>
    <key>CFBundleExecutable</key><string>Forge</string>
    <key>CFBundleIdentifier</key><string>com.forge.mlx</string>
    <key>CFBundleName</key><string>Forge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
$ICON_PLIST
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Forge — native MLX runtime</string>
</dict>
</plist>
PLIST

echo "── sign (ad-hoc, local testing only) ────────────────"
# Sign inside-out: nested Mach-O (Metal library + llama.framework) first, then
# the bundle. The framework must be signed before the outer bundle or the
# enclosing signature won't seal it and Gatekeeper/dyld will reject it.
[[ -f "$APP/Contents/MacOS/mlx.metallib" ]] && \
  codesign --force --sign - "$APP/Contents/MacOS/mlx.metallib"
[[ -d "$APP/Contents/Frameworks/llama.framework" ]] && \
  codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
if [[ "$SANDBOX" -eq 1 ]]; then
  codesign --force --sign - --entitlements "$ENT" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "── verify ────────────────────────────────────────────"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier|Signature|flags' || true
if [[ "$SANDBOX" -eq 1 ]]; then
  echo "sandbox entitlement:"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -A0 'app-sandbox' || echo "  (checking…)"
else
  echo "sandbox entitlement: disabled for local stdio MCP developer build"
  if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'app-sandbox'; then
    echo "FATAL: app-sandbox entitlement is still present"
    exit 1
  fi
fi

if [[ "$INSTALL_DEST" == "/Applications" ]]; then
  echo "── install to /Applications ──────────────────────────"
  rm -rf /Applications/Forge.app
  cp -R "$APP" /Applications/Forge.app
  echo "Installed /Applications/Forge.app"
fi

echo "── done ──────────────────────────────────────────────"
echo "Run it:   open '$APP'"
echo "NOTE: ad-hoc signed = runs on THIS Mac. For TestFlight/other testers,"
echo "      sign with your Apple cert (see MacAppStore/SUBMISSION_CHECKLIST.md)."
