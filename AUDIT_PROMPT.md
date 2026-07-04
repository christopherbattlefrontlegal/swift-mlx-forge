# Forge — Complete Pre-Ship Code Audit Prompt

Paste everything below this line into a fresh Claude Code session started in
`/Volumes/TB4_1TB/swift-mlx-forge`.

---

You are doing a final pre-ship audit of Forge, a native macOS SwiftUI app
(`Sources/mlx-forge/`, built by `scripts/build-app.sh` into `Forge.app`) that
runs local LLMs on two engines: MLX (mlx-swift-lm, safetensors) and llama.cpp
(GGUF, via the vendored package at `Vendor/LLM.swift` whose
`llama.xcframework` was upgraded to llama.cpp b9870 for `nemotron_h_moe`
support). This audit is the last gate before shipping. Find real defects and
fix them — do not report style nits.

## Recent changes to scrutinize first (highest regression risk)

1. `Sources/mlx-forge/ChatView.swift` — `StreamingPlainTextView` was rewritten
   from an AppKit NSTextView wrapper to plain SwiftUI `Text`. History: v1 had
   no height reporting (live tokens invisible/misplaced); v2 measured via
   `sizeThatFits` mutating the text container (window-wide relayout flashing
   every flush). Current version must: render live reasoning + answer text
   growing smoothly, no flashing, acceptable CPU with 10k+ token outputs at
   the 120ms flush cadence in `AppState.enqueueStreamDelta`.
2. `Sources/mlx-forge/GGUFRuntime.swift` + `Sources/mlx-forge/InferenceEngine.swift`
   (`loadGGUF`, `GGUFLoadProgressThrottle`) + `Vendor/LLM.swift/Sources/LLM/LLM.swift`
   (`loadProgress` parameter, `LoadProgressBox`) — llama.cpp's
   `progress_callback` newly wired through to `loadingModels[modelID]` so GGUF
   loads show percent. Verify: callback thread-safety (fires on llama's loader
   thread), no retain cycles, box lifetime across the whole
   `llama_model_load_from_file` call, throttle correctness (monotonic, 0→100),
   UI updates land on MainActor, and the `defer { loadingModels.removeValue }`
   in `loadGGUF` cannot race the async progress hops (a late `Task { @MainActor }`
   must not resurrect a removed key — check the `contains` guard is sufficient).
3. `Package.swift` — LLM.swift moved from the GitHub 2.1.0 tag to
   `.package(path: "Vendor/LLM.swift")`. Verify a clean checkout builds:
   `swift build --product mlx-forge` and `./scripts/build-app.sh`.

## Full audit scope (top to bottom, after the three above)

- **Streaming pipeline**: `InferenceEngine.generate` / `generateGGUF` /
  `streamMLXResponse` / `streamBudgetedMLXResponse` → `AppState.enqueueStreamDelta`
  → `ThinkTagParser` → `flushStreamBuffer`/`finishStreamBuffer` →
  `TranscriptView`/`MessageRow`/`LiveThinkingBlock`. Hunt: dropped/duplicated
  deltas, reasoning misrouted to content (or vice versa), parser stuck states
  (`<think` split across deltas, missing `</think>` at EOS, models that never
  emit `<think>`), stop-mid-stream leaving `streamingMessageIDs` stale
  (spinner forever / composer locked), the `.equatable()` gate on `MessageRow`
  suppressing needed re-renders.
- **Cancellation & lifecycle**: `stop()`, `unload()`, `shutdown()`, quit during
  a 100GB GGUF load, unload-while-generating, send-while-loading. GGUF loads
  have no cancel path today — confirm nothing crashes if the user quits mid-load.
- **Concurrency**: everything crossing `@MainActor` ↔ `MLXGate` ↔ detached
  tasks ↔ llama loader thread. `GGUFRuntime` is `@unchecked Sendable`;
  `LLM.swift`'s `LLMCore` actor calls; `liveTokenCount` updates. Look for data
  races Swift 6 would reject that the swift-5 language mode lets slide.
- **Memory**: `ModelMemoryBudget` admission vs reality for GGUF (mmap +
  Metal buffers), `Memory.cacheLimit`, purge-during-flight guards
  (`scheduleCachePurge` comment claims discipline — verify call sites).
- **GGUF correctness**: template pick in `GGUFRuntime.template(system:)`
  (filename heuristics) vs actual model families users will load (Nemotron 3 →
  chatML is correct); history mapping (`isErrorMessage` filtering); context
  sizing (`maxKVSize`→131072 clamp) on huge-context models.
- **Error surfacing**: every `catch`/`guard-else-nil` path in load/generate —
  the user must never be left with a silently idle UI. `lastError` display
  coverage in `WelcomeView`, `liveBar`, `ModelBrowserView`.
- **API server** (`ForgeServer.swift`): same streaming + gate discipline as the
  UI path; a server request during a UI generation must queue, not interleave.
- Build/package: `scripts/build-app.sh` correctness (stale-product traps,
  llama.framework copy + rpath + signing order).

## Method

For each area: read the code, trace the failure scenario concretely (inputs →
state → wrong outcome), and only report findings you can defend with
`file:line`. Then apply the fixes with minimal diffs, keeping the existing
style. After edits: `swift build --product mlx-forge` must pass; then run
`./scripts/build-app.sh` and report the result. Deliver a final list ordered
by severity: (1) would crash or hang, (2) wrong output shown to user,
(3) misleading UI state, (4) everything else. State plainly anything you
could not verify by execution.
