# Forge — Security Review (2026-06-10)

Read-only review of `Sources/mlx-forge/` (16 Swift files) plus a hardcoded-secret
grep across the whole `Sources/` tree, and a static inspection of the shipped
`/Applications/Forge.app` binary. No files were modified.

## Severity summary

| ID | Sev | Title |
|----|-----|-------|
| H-1 | HIGH | Wildcard CORS (`Access-Control-Allow-Origin: *`) on an unauthenticated loopback API server — reachable from any website |
| H-2 | HIGH | Unauthenticated endpoint can force arbitrary local model loads (memory-exhaustion DoS) |
| M-1 | MED | Headless launcher spawns external `claude` with opt-in "no guardrails" mode — incompatible with App Sandbox |
| M-2 | MED | Force-unwraps on the model-search request path |
| M-3 | MED | 256 MB request body fully buffered; no per-connection timeout |
| L-1 | LOW | `ANTHROPIC_API_KEY` injected into child process environment |
| L-2 | LOW | `models--org--name` → display-name reconstruction (display only, no traversal) |
| L-3 | LOW | Internal error `localizedDescription` (with local paths) reflected to network clients |
| L-4 | LOW | Extra model dirs persisted as plain paths, re-scanned on launch |
| L-5 | LOW | Persistence files written without explicit `0600`/`0700` perms |

## HIGH — details and fixes

### H-1. Wildcard CORS + no auth on the local server
`ForgeServer.swift:416-419` (CORS), `:124-138` (no auth), `:125-127` (OPTIONS always
204). Server binds to `127.0.0.1` only (`:66-68`, good) but returns
`Access-Control-Allow-Origin: *` and allows `Authorization`/`Content-Type`/`POST`.
Loopback binding does NOT protect against the user's own browser: any visited web
page can `fetch("http://127.0.0.1:<port>/v1/chat/completions", …)` and read the
response. Auto-starts on launch when enabled (`AppState.swift:124-127`).
**Fix:** remove wildcard CORS; check `Origin`/`Host` against loopback; require a
generated bearer token (Keychain) on `/v1/*`.

### H-2. Unauthenticated model load
`ForgeServer.swift:166-229`, `resolveModel` `:220-229` → `engine.load(...)`.
`POST /v1/chat/completions` auto-loads any installed cold model named in the body.
With H-1, a web page can force a large model into unified memory + run inference,
no consent, no rate limit. (Not a path-traversal vector — `resolveModel` only
matches `store.localModels` by name, `:223-225`.) **Fix:** auth + rate/concurrency
limit + require models be explicitly exposed.

## MED — App Store blocker

### M-1. Headless `claude` launcher
`HeadlessLauncher.swift:152-209` (`Process()` at `:165`), `fullAuto` →
`--dangerously-skip-permissions` (`:47`). **Positive:** args passed as an argv
array (no shell injection), binary resolved from a fixed allowlist (`:140-148`),
mandatory `SafetyCheckpointView` before full-auto (`LauncherView.swift:219-322`).
**But:** spawning an external agent that can modify/execute files anywhere is
fundamentally incompatible with the MAS App Sandbox. Remove from the MAS target or
ship only via Developer ID.

## Positive observations (verified clean)

1. Server binds to loopback only (`ForgeServer.swift:66-68`) — nothing on `0.0.0.0`.
2. Secrets in macOS **Keychain** via `SecItem*` (`SecretsStore.swift`), not files/UserDefaults.
3. **No hardcoded credentials** anywhere — grep across `Sources/` found only UI
   placeholders (`hf_xx…`, `sk-ant-…`). Confirmed against the shipped binary too
   (only the `hf_xxxxxxxxxxxxxxxxxxxx` placeholder string is embedded).
4. **All network calls use HTTPS**; only non-HTTPS string is the loopback server's
   own base URL. No `NSAllowsArbitraryLoads`, no TLS-validation overrides.
5. HF bearer token sent only to `huggingface.co` over TLS (`ModelStore.swift:289-291`).
6. No shell-string execution anywhere (`/bin/sh -c`, `system()`, `posix_spawn`) — argv arrays only.
7. No path traversal from remote input.
8. Tolerant JSON decoding with size caps; no unsafe deserialization.

## Binary-level checks (`/Applications/Forge.app`)
- Links only system frameworks + Swift runtime; no suspicious dylibs.
- `LC_RPATH` includes a local Xcode toolchain path (`…XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx`) — harmless but a re-sign/rebuild with the release toolchain will clean it up.
- arm64 thin, ad-hoc signed, Gatekeeper-rejected (expected for an unsigned local build).
