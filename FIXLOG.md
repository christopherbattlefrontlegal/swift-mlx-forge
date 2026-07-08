# FIXLOG.md — EVAL.md corrections

## Batch 1 — Finding #1 (BUG: dispatchToAgent never calls endStreaming)

- **What changed:** `Sources/mlx-forge/AppState.swift` — in `dispatchToAgent`'s
  work-task defer, added `self.endStreaming(messageID: messageID)` immediately
  after `self.finishStreamBuffer(messageID)`. This closes the streaming state
  machine on all three agent backends (local / Claude / OpenRouter), including
  the missing-key early returns, since the defer runs on every exit path.
- **Build:** `swift build` → Build complete! (33.10 sec), no errors.

## Batch 2 — Findings #2, #4, #5 (BUGs in InferenceEngine.swift)

- **#4 (silent fallback to active model):** `generate()` now fails the turn
  with `onComplete(nil, "Model is no longer loaded.")` when `targetModelID` is
  set but absent from `loadedModels`, instead of silently answering from
  `activeModel` under the wrong label.
- **#5 (stop + resend breaks accounting):** replaced the raw
  `activeGenerationCount` integer with `activeGenerationIDs: Set<UUID>`.
  `beginGeneration()` inserts the new ID; `finishGeneration(generationID)` only
  decrements if it can remove its own ID; `stop()`/`shutdown()` empty the set.
  A cancelled generation draining after `stop()` can no longer flip
  `isGenerating` off while a newer generation is live. All 7
  `finishGeneration()` call sites updated (each already had `generationID`
  captured).
- **#2 (GGUF load races):** `loadGGUF` now mirrors the MLX path's bookkeeping:
  new `ggufLoadTasks[model.id]` in-flight task so concurrent callers await one
  `GGUFRuntime` creation; `loadGenerations` bumped at entry and
  `discardedLoads` cleared there; the cleanup `defer` and the load-progress
  callback are both guarded on the captured generation; after awaiting, the
  load throws `CancellationError` if discarded OR superseded
  (`loadGenerations != generation`), and returns the existing entry if a
  concurrent caller already appended it. `cancelInFlightLoad` and
  `tearDownLoadedModels` now also clear `ggufLoadTasks`.
- **Build:** `swift build` → Build complete! (11.41 sec), no errors.

## Batch 3 — Findings #3, #6 (BUGs: server timeout leak, MCP stdio races)

- **#3 (ForgeServer.receive timeout leaves the continuation unresumed):** the
  timeout child in `HTTPRequest.receive` now calls `connection.cancel()` before
  throwing `URLError(.timedOut)`. Cancelling the transport makes the pending
  `NWConnection.receive` callback fire with an error, resuming the checked
  continuation so the task group can drain and propagate the timeout — an idle
  (slowloris) socket is now actually dropped after 15 s instead of leaking the
  task + connection forever.
- **#6 (MCP stdio concurrent request corruption):** `MCPStdioSession` gained a
  `requestLock` held for the whole `request()` send + read-until-my-id
  exchange, serializing concurrent `callTool`s on one session so parallel
  agents can no longer interleave stdin writes or consume each other's replies.
- **Build:** `swift build` → Build complete! (10.49 sec), no errors.

## MINOR findings (7–10) — intentionally NOT fixed

EVAL.md's job list for this pass is "every BLOCKER and BUG finding — nothing
else"; findings 7–10 are MINOR and left as documented.

## Final verification

- `swift build` (debug, full tree after all batches): recorded above per batch;
  re-run at the end — see below.
- `./scripts/build-app.sh /Applications`: run from the root checkout after the
  branch fast-forward. Output tail:

  ```
  Build complete! (176.06 sec)
  ── assemble bundle ───────────────────────────────────
  ── sign (ad-hoc, local testing only) ────────────────
  ── verify ────────────────────────────────────────────
  Identifier=com.forge.mlx
  Signature=adhoc
  sandbox entitlement: disabled for local stdio MCP developer build
  ── install to /Applications ──────────────────────────
  Installed /Applications/Forge.app
  ── done ──────────────────────────────────────────────
  ```

  (Only pre-existing warnings in the release build — SecretsStore.swift:83 and
  WeightLoading.swift:104 `var` never mutated; none in the files touched by
  this pass.)
