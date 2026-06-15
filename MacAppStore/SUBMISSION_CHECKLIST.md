# Forge — Mac App Store Submission Checklist

Prepared 2026-06-10. The app currently in `/Applications/Forge.app` is an **ad-hoc
signed** Swift Package build — it is NOT ready to upload as-is. This document lists
exactly what's blocking, what's missing, and the steps to get there. Code signing
is intentionally left for you to do.

---

## Current state of the build (what I inspected)

| Item | Finding |
|---|---|
| Bundle ID | `com.forge.mlx` |
| Version / Build | `1.0` / `1` |
| Architecture | arm64 only (Apple Silicon) |
| Min macOS | 14.0 |
| Signature | **ad-hoc** (`Signature=adhoc`, `TeamIdentifier=not set`) |
| Gatekeeper (`spctl`) | **rejected** |
| App Sandbox | **not enabled** (no entitlements at all) |
| App icon | **none** (no `CFBundleIconFile`, no `.icns`) |
| Built with | Swift 6.2 toolchain via SwiftPM, not an Xcode app target |

---

## BLOCKERS — must fix before submission

### 1. Headless launcher is incompatible with App Sandbox (architectural)
`Sources/mlx-forge/HeadlessLauncher.swift` spawns an external `claude` binary via
`Process()` and offers a `--dangerously-skip-permissions` "full auto" mode. A
sandboxed MAS app **cannot** execute an arbitrary external binary that roams the
filesystem. This feature must be **removed from the App Store target** (or shipped
only in a separate Developer-ID build distributed outside the store).

### 2. Local server: wildcard CORS + no authentication (security — HIGH)
`Sources/mlx-forge/ForgeServer.swift` binds to loopback (good) but answers every
request with `Access-Control-Allow-Origin: *` and no auth. Any website the user
visits can call `http://127.0.0.1:<port>/v1/chat/completions`, read the response,
enumerate models, and force large local model loads (memory-exhaustion DoS).
Fixes:
- Drop wildcard CORS; reject cross-origin / non-loopback `Host` and `Origin`.
- Require a generated bearer token (store in Keychain, show in UI) on `/v1/*`.
- Add a concurrency/rate limit and lower the 256 MB body cap to a few MB.
- Stop reflecting `error.localizedDescription` (leaks local paths) to clients.

### 3. No App Sandbox entitlements
Add the provided `MacAppStore/Forge.entitlements` at signing time. MAS rejects any
unsandboxed app.

### 4. No code-signing identity / no app icon
- Sign with **Apple Distribution** + provisioning profile, and the installer pkg
  with **3rd Party Mac Developer Installer** (a.k.a. Apple Distribution for MAS).
  (You said you'll do this when you wake up — leaving it to you.)
- Add an `AppIcon.icns` and set `CFBundleIconFile`. MAS rejects apps with no icon.

---

## 2026 platform requirements (post-WWDC 2026)

- **Xcode 26 + the 26 SDK are mandatory** for all App Store Connect uploads
  effective **April 28, 2026**. Your current bundle was built with the Swift 6.2
  toolchain via SwiftPM — for submission you must build the app target in
  **Xcode 26** (or `xcodebuild` from Xcode 26) so it links the macOS 26 SDK.
- **Notarization** is required for Developer-ID distribution; for the **Mac App
  Store** path, App Review handles equivalent checks — but use `notarytool`
  (not the retired `altool`) if you also ship a Developer-ID build.
- Recommend building a **universal binary** (arm64 + x86_64) unless you intend to
  ship Apple-Silicon-only; the current binary is arm64-only.

---

## Other items needed for App Store Connect

- [ ] Real **Team ID** in the signature (currently "not set").
- [ ] **Privacy nutrition labels** — the app stores chat transcripts locally and
      sends a bearer token to huggingface.co; declare data use accurately.
- [ ] **Export-compliance** answer: the app uses HTTPS/TLS (standard crypto) — the
      usual exemption applies, but you must answer the question.
- [ ] Screenshots, description, category (Info.plist already sets
      `public.app-category.developer-tools`), support URL, privacy-policy URL.
- [ ] Bump `CFBundleVersion` per upload.
- [ ] Confirm bundled `mlx.metallib` and any model files are acceptable / not
      shipping large model weights inside the bundle.

---

## Suggested signing/packaging steps (for when you sign it)

These are the canonical commands — fill in your identities. **Do not run these
until the blockers above are fixed; signing an unsandboxed, CORS-open build just
produces a rejectable upload faster.**

```sh
# 1. Build the app target in Xcode 26 (links macOS 26 SDK). Example:
#    xcodebuild -scheme Forge -configuration Release -derivedDataPath build \
#      CODE_SIGN_IDENTITY="Apple Distribution: <Your Name> (TEAMID)" \
#      OTHER_CODE_SIGN_FLAGS="--entitlements MacAppStore/Forge.entitlements"

# 2. Sign with App Sandbox entitlements (your cert):
codesign --force --options runtime --timestamp \
  --entitlements MacAppStore/Forge.entitlements \
  --sign "Apple Distribution: <Your Name> (TEAMID)" \
  /path/to/Forge.app

# 3. Build the signed installer package for the store:
productbuild --component /path/to/Forge.app /Applications \
  --sign "3rd Party Mac Developer Installer: <Your Name> (TEAMID)" \
  Forge.pkg

# 4. Validate, then upload:
xcrun altool --validate-app -f Forge.pkg -t macos   # or Transporter app
xcrun notarytool ...   # only for the Developer-ID build, not MAS
```

## Full security findings
See the security review summary in the chat / `MacAppStore/SECURITY_REVIEW.md`.
The Keychain handling, HTTPS-only networking, no-hardcoded-secrets, and
argv-array (no shell injection) process spawning all checked out clean — the
blockers are the unauth'd server and the sandbox-incompatible launcher.
