#!/usr/bin/env bash
# Forge — assemble a runnable local developer .app from the release build.
#
# Default output is intentionally unsandboxed so stdio MCP servers can launch
# node/npx/uv/python MCP commands. Use --mas-sandbox when you
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
EXE="$ROOT/.build/release/mlx-forge"
METALLIB="$ROOT/.build/release/mlx.metallib"
DESIGN_PROMPT_DIST="$ROOT/BundledTools/ai-design-prompt/dist"
RIVET_DIST="$ROOT/BundledTools/rivet/dist"
# llama.cpp (GGUF) backend, packaged as a framework by LLM.swift. The Forge binary
# links it as @rpath/llama.framework/...; if it's not bundled, dyld aborts the app
# at launch ("Library not loaded: @rpath/llama.framework"). Must be copied into
# Contents/Frameworks and signed inside-out.
LLAMA_FW="$ROOT/.build/release/llama.framework"
APP="$ROOT/Forge.app"
INSTALL_DEST=""
SANDBOX=0

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    echo "Install Xcode/Xcode command line tools, then rerun this script." >&2
    exit 1
  fi
}

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

echo "── preflight ─────────────────────────────────────────"
"$ROOT/scripts/check-toolchain.sh"
need_tool xcrun
need_tool codesign
need_tool install_name_tool
if [[ ! -f "$DESIGN_PROMPT_DIST/index.html" ]]; then
  need_tool npm
fi
if [[ ! -f "$RIVET_DIST/index.html" ]]; then
  need_tool node
fi

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

if [[ ! -f "$DESIGN_PROMPT_DIST/index.html" ]]; then
  echo "Design prompt bundle missing — building BundledTools/ai-design-prompt…"
  (cd "$ROOT/BundledTools/ai-design-prompt" && npm install && npm run build)
fi
[[ -f "$DESIGN_PROMPT_DIST/index.html" ]] || { echo "FATAL: Design prompt dist missing ($DESIGN_PROMPT_DIST). Aborting."; exit 1; }

if [[ ! -f "$RIVET_DIST/index.html" ]]; then
  echo "Rivet bundle missing — building vendored Ironclad Rivet frontend…"
  "$ROOT/scripts/build-rivet.sh"
fi
[[ -f "$RIVET_DIST/index.html" ]] || { echo "FATAL: Rivet dist missing ($RIVET_DIST). Aborting."; exit 1; }

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
mkdir -p "$APP/Contents/Resources/DesignPrompt"
cp -R "$DESIGN_PROMPT_DIST/"* "$APP/Contents/Resources/DesignPrompt/"
mkdir -p "$APP/Contents/Resources/Rivet" "$APP/Contents/Resources/ThirdPartyLicenses"
cp -R "$RIVET_DIST/"* "$APP/Contents/Resources/Rivet/"
cp "$ROOT/BundledTools/rivet/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/Rivet-MIT.txt"
cat > "$APP/Contents/Resources/mcp.json" <<'JSON'
{
  "mcpServers": {
  }
}
JSON

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
    <key>CFBundleShortVersionString</key><string>2.0.1</string>
    <key>CFBundleVersion</key><string>3</string>
$ICON_PLIST
    <key>ForgeMCPConfigPath</key><string></string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Forge — native MLX runtime</string>
</dict>
</plist>
PLIST

# Pick a signing identity. A real certificate gives the app a STABLE code
# signature, which is what makes Keychain "Always Allow" actually stick: the
# ACL is bound to the signature, so an ad-hoc build gets a new identity on
# every compile and macOS re-prompts for the password every single time.
#
# Preference order: explicit override, Developer ID (distributable), Apple
# Development (local), then ad-hoc as a last resort.
resolve_sign_id() {
  if [[ -n "${FORGE_SIGN_ID:-}" ]]; then
    printf '%s' "$FORGE_SIGN_ID"
    return
  fi
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  local found
  found="$(printf '%s\n' "$identities" | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')"
  if [[ -z "$found" ]]; then
    found="$(printf '%s\n' "$identities" | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')"
  fi
  printf '%s' "${found:--}"
}

SIGN_ID="$(resolve_sign_id)"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "── sign (ad-hoc — no certificate found) ─────────────"
  echo "   No signing certificate in your keychain, so this build is ad-hoc."
  echo "   macOS will re-ask for your keychain password after every rebuild."
else
  echo "── sign ($SIGN_ID) ──"
fi

# Sign inside-out: nested Mach-O (Metal library + llama.framework) first, then
# the bundle. The framework must be signed before the outer bundle or the
# enclosing signature won't seal it and Gatekeeper/dyld will reject it.
[[ -f "$APP/Contents/MacOS/mlx.metallib" ]] && \
  codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/mlx.metallib"
[[ -d "$APP/Contents/Frameworks/llama.framework" ]] && \
  codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/llama.framework"
if [[ "$SANDBOX" -eq 1 ]]; then
  codesign --force --sign "$SIGN_ID" --entitlements "$ENT" "$APP"
else
  codesign --force --sign "$SIGN_ID" "$APP"
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
  osascript -e 'tell application "Forge" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Forge.app
  cp -R "$APP" /Applications/Forge.app
  echo "Installed /Applications/Forge.app"
  echo "MCP config: ~/Library/Application Support/Forge/mcp.json (seeded empty on first launch)"
fi

echo "── done ──────────────────────────────────────────────"
echo "Run it:   open '$APP'"
case "$SIGN_ID" in
  -)
    echo "NOTE: ad-hoc signed = runs on THIS Mac, and macOS re-asks for your"
    echo "      keychain password after every rebuild."
    ;;
  "Developer ID Application:"*)
    echo "NOTE: Developer ID signed. Notarize before sending to other Macs"
    echo "      (see MacAppStore/SUBMISSION_CHECKLIST.md)."
    ;;
  *)
    echo "NOTE: signed with a development certificate — stable identity, so"
    echo "      Keychain 'Always Allow' now persists across rebuilds. Other Macs"
    echo "      still need a Developer ID cert + notarization."
    ;;
esac
echo "      Override the identity with: FORGE_SIGN_ID='...' ./scripts/build-app.sh"
