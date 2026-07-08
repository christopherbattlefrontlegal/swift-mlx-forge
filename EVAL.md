# EVAL.md — Forge audit (read-only pass)

Scope: build health, chat/agent loop (AppState.swift), inference lifecycle
(InferenceEngine.swift), local API server (ForgeServer.swift), verification of
three previously-reported defects, persistence round-trip, and a quick pass over
ChatView.swift, MCP.swift, HeadlessLauncher.swift. All line numbers are from the
tree at commit `ec01db74` (branch `codex/clean-source-install`).

## 0. Build health

`swift build 2>&1 | tail -20` → **PASS** — `Build complete! (15.47 sec)`.
Two pre-existing warnings (implicit strong capture of `self`,
`Sources/mlx-forge/InferenceEngine.swift:232` and `:322`). No errors.

---

## FINDINGS

### 1. BUG — `dispatchToAgent` never calls `endStreaming` on any path
**File:** `Sources/mlx-forge/AppState.swift:1376` (begin), `:1383–1392` (defer), `:1422–1441` (local onComplete), `:1450–1503` / `:1505–1565` (agent stream helpers)

`dispatchToAgent` calls `beginStreaming(messageID:)` at AppState.swift:1376. The
work task's defer (AppState.swift:1386–1391) runs `finishStreamBuffer`,
removes the agent label and task — but never calls `endStreaming(messageID:)`.
None of the three backend branches call it either: the local branch's
`onComplete` (AppState.swift:1422–1441) ends with `appendToMessage` only, and
`runClaudeAgentStream` / `runOpenRouterAgentStream` call only
`finishStreamBuffer` (AppState.swift:1495, 1557). Every other send path pairs
begin/end correctly (e.g. fan-out at 1184→1224, single local 1257→1305, cloud
guard-fail paths 1581/1656/1733/1803, MCP follow-up 2011→2059) — agent dispatch
is the one path that doesn't.

**Failure scenario:** click any agent button in the dispatch popover. When the
reply finishes, the message ID stays in `streamingMessageIDs` forever:
`isMessageStreaming` stays true so the bubble's spinner never stops
(ChatView.swift:308–311), the row keeps rendering from the live-stream branch,
`streamingTextByMessageID`/`streamingReasoningByMessageID` entries leak, Smart
Select replies are never scanned (endStreaming is what triggers
`applySmartSelectedPromptIfPresent`, AppState.swift:2143–2145), and
`streamingMessageID` stays non-nil so `deleteConversation` (AppState.swift:813)
fires `stopGenerating()` and kills unrelated live streams long after the agent
finished.

**Smallest fix:** in the `work` task's defer (AppState.swift:1386–1391), call
`self.endStreaming(messageID: messageID)` right after
`self.finishStreamBuffer(messageID)`. finishStreamBuffer has already copied the
buffered text into the stored message, so removing the live-buffer entries there
is safe on all three backend branches, including the missing-key early returns.

### 2. BUG — GGUF load path has no in-flight dedup or load-generation guard
**File:** `Sources/mlx-forge/InferenceEngine.swift:286–355`

The MLX path guards concurrent/stale loads three ways: an in-flight
`loadTasks[model.id]` that concurrent callers await (InferenceEngine.swift:188–192),
a `loadGenerations` counter so a superseded load's defer doesn't clean up the
newer load's state (InferenceEngine.swift:205–207, 240–246), and
`discardedLoads.remove(model.id)` at the start of a fresh load
(InferenceEngine.swift:199). `loadGGUF` has none of these: no task dedup, no
generation counter, an unconditional `defer { loadingModels.removeValue(forKey:
model.id) }` (InferenceEngine.swift:303), a progress callback guarded only by
key membership (InferenceEngine.swift:322–330), and `discardedLoads` consumed
only at completion (InferenceEngine.swift:343–346) and never cleared at entry.

**Failure scenarios:**
(a) UI load + API auto-load (ForgeServer `resolveModel` →
`engine.load`, ForgeServer.swift:358–367) race on the same cold GGUF: the
`loadedModels.first` early-return (InferenceEngine.swift:164–166) misses because
neither finished, both construct a `GGUFRuntime` → doubled RAM and two duplicate
`loadedModels` entries with the same id.
(b) Unload mid-load, then reload before the first load lands: `cancelInFlightLoad`
inserts the id into `discardedLoads` (InferenceEngine.swift:448); if the *reload*
finishes first, line 343 consumes the flag meant for the stale load — the reload
throws `CancellationError` (user sees nothing load) and the stale, "unloaded"
load then appends its entry, resurrecting the ejected model.
(c) Whichever concurrent load finishes first removes `loadingModels[model.id]`
via the unconditional defer, killing the still-loading one's progress banner;
the stale load's progress callbacks also keep writing into the newer load's
entry (key check passes), so the percent jumps backward.

**Smallest fix:** mirror the MLX bookkeeping: bump/record
`loadGenerations[model.id]` at loadGGUF entry, clear `discardedLoads` there,
keep an in-flight task entry so concurrent callers await the same load, and
guard both the `defer` cleanup and the progress callback on the captured
generation.

### 3. BUG — `ForgeServer.receive` timeout never resumes the receive continuation, leaking the connection and its task
**File:** `Sources/mlx-forge/ForgeServer.swift:748–775`

`receive` races an `NWConnection.receive` wrapped in
`withCheckedThrowingContinuation` against a 15 s sleep in a
`withThrowingTaskGroup`. When the timeout child throws, `group.next()` rethrows
— but a throwing task group must await *all* children before propagating, and
the receive child is suspended on a checked continuation that has no
cancellation handler. `group.cancelAll()` (ForgeServer.swift:770) cancels the
Swift task, but nothing cancels the `NWConnection`, so for an idle (slowloris)
socket the receive callback never fires, the continuation never resumes, and
`receive` never returns. Consequently `HTTPRequest.read` never throws, the
`connection.cancel()` in `accept` (ForgeServer.swift:156) is never reached, and
the request task + socket leak permanently. The 15 s "per-read deadline"
documented at ForgeServer.swift:744–746 is dead code in exactly the case it was
written for.

**Failure scenario:** with the API server enabled, any client that opens a TCP
connection to the port and sends nothing pins one task + one socket forever;
repeated connections accumulate without bound.

**Smallest fix:** make the timeout actually tear down the transport so the
pending receive callback fires with an error and resumes the continuation —
e.g. in the timeout child, after `Task.sleep`, call `connection.cancel()`
before throwing. The group can then drain and propagate `URLError(.timedOut)`.

### 4. BUG — targeted generation silently falls back to the active model when the target is gone
**File:** `Sources/mlx-forge/InferenceEngine.swift:505–513`

```swift
if let tid = targetModelID, let t = loadedModels.first(where: { $0.id == tid }) {
    entry = t
} else {
    entry = activeModel
}
```
If `targetModelID` is non-nil but no longer loaded (user ejected it between
dispatch and generation, or an MCP follow-up fires after an unload —
AppState.swift:2035 passes a captured `modelID`), the reply silently streams
from whatever model happens to be active, under the *original* model's label
in the transcript. In local fan-out that means two bubbles labeled as different
models can both be answered by the same model.

**Failure scenario:** fan-out to models A and B; eject B while A is streaming
(B's generate is queued behind the gate); B's bubble is then generated by A but
labeled B — silently wrong attribution, no error.

**Smallest fix:** when `targetModelID` is non-nil and not found in
`loadedModels`, call `onComplete(nil, "Model is no longer loaded.")` and return
instead of falling through to `activeModel`.

### 5. BUG — `stop()` zeroes generation accounting while cancelled streams are still draining
**File:** `Sources/mlx-forge/InferenceEngine.swift:729–762`

`stop()` cancels all generation tasks and immediately sets
`activeGenerationCount = 0; isGenerating = false`
(InferenceEngine.swift:739–740). But a cancelled stream still drains inside its
gate turn and then calls `finishGeneration()` (InferenceEngine.swift:570, 616,
643, 647, 708). If the user re-sends before that drain completes,
`beginGeneration()` sets count = 1 / `isGenerating = true`
(InferenceEngine.swift:744–754); the *old* task's `finishGeneration()` then
decrements it back to 0 and flips `isGenerating = false` while the new
generation is live.

**Failure scenario:** Stop → immediately resend. Mid-answer, the live bar
disappears, `isBusy` goes false, `canSend` re-enables, and the
`guard targetModelID != nil || !isGenerating` protection
(InferenceEngine.swift:515) lets a second concurrent UI generation be queued
into the same conversation — double replies and broken busy state.

**Smallest fix:** track live generation IDs in a `Set<UUID>`:
`beginGeneration()` inserts the new ID, `finishGeneration(_ id:)` decrements
only if `remove(id)` succeeds, and `stop()` empties the set. All
`finishGeneration()` call sites already have `generationID` captured in scope.

### 6. BUG — concurrent tool calls on one MCP stdio session interleave writes and steal replies
**File:** `Sources/mlx-forge/MCP.swift:1175–1224`

`MCPStdioSession.callTool` locks only the request-ID increment
(MCP.swift:1176–1179). `send` (MCP.swift:1220–1224) performs two unlocked
`FileHandle.write` calls (body, then newline), and `request`'s read loop
(MCP.swift:1197–1208) pops messages off the shared buffer and *discards* every
payload whose id doesn't match its own. `MCPManager.callTool` invokes this from
`Task.detached` (MCP.swift:698–702), so two parallel agents (dispatchToAgent /
fan-out) calling tools on the same stdio server run this concurrently: reply A
can be consumed and dropped by reader B, and interleaved writes can corrupt the
JSON-RPC framing.

**Failure scenario:** two agent bubbles both call desktop-commander tools at
once → one call hangs 90 s and fails with "Timed out waiting for MCP stdio
response" even though the server answered.

**Smallest fix:** add a per-session request lock (e.g. an `NSLock` acquired for
the whole `send` + read-until-my-id sequence in `request`), serializing
concurrent `callTool`s on one session. Blocking is already the session's model
(`readMessage` polls with `Thread.sleep` off-main).

### 7. MINOR — stale MLX load-progress callbacks write into a newer load's entry
**File:** `Sources/mlx-forge/InferenceEngine.swift:229–235`

The MLX progress callback guards only on `loadingModels.keys.contains(modelID)`.
After cancel-then-reload of the same model, the superseded load's still-running
loader keeps reporting fractions into the *new* load's `loadingModels` entry
(same key), so the progress banner can jump backward. Cosmetic; the
`loadGenerations` defer prevents any state damage. Fix: capture the generation
in the callback and drop reports when `loadGenerations[modelID]` moved on.

### 8. MINOR — stream deltas arriving after `stopGenerating` recreate orphaned buffer entries
**File:** `Sources/mlx-forge/AppState.swift:2577–2615`

`stopGenerating` clears all streaming dictionaries (AppState.swift:2552–2557),
but a cancelled provider stream can still deliver a few buffered deltas.
`enqueueStreamDelta` unconditionally recreates `streamBufferConversationIDs`
and schedules a flush that re-adds `streamingTextByMessageID[messageID]`
(AppState.swift:2614) for a message whose streaming already ended — and nothing
removes those entries afterwards. No UI effect (`isMessageStreaming` is false);
just slow unbounded dictionary growth across a long session. Fix: guard
`enqueueStreamDelta` on `streamingMessageIDs.contains(messageID)`.

### 9. MINOR — an undecodable conversations.json is silently replaced on the next save
**File:** `Sources/mlx-forge/Persistence.swift:172–177`

`loadState()` returns an empty `PersistedState` on *any* read/decode failure;
the next `saveNow()` then overwrites the file with the empty state. Writes are
atomic (Persistence.swift:181) and `ChatMessage`/`Conversation` use synthesized
decoding with defaulted fields, so this is unlikely in practice — but a file
written by a future build with an incompatible required field would wipe all
chats on downgrade. Fix idea (2 lines): before overwriting after a failed
decode, copy the unreadable file to `conversations.json.bak`.

Settings round-trip itself is **SOUND**: `PersistedSettings`
(Persistence.swift:115–156) and `GenerationSettings` (Models.swift:358–400)
both decode field-by-field with defaults, including the legacy
`localThinkingEffort` migration; every field written in `saveNow`
(AppState.swift:2674–2703) is restored in `AppState.init`
(AppState.swift:559–608). Nothing loses user data on a normal round-trip.

### 10. MINOR — "All agents at once" dispatches to every cloud model regardless of keys, and skips the empty-composer fallback
**File:** `Sources/mlx-forge/ChatView.swift:1312–1332`

`dispatchToAll()` iterates all `AnthropicClient.models` and all
`OpenRouterClient.models` even when no API key is configured — producing a
column of "No … API key" error bubbles (each also hitting finding #1). Unlike
`dispatchTo` (ChatView.swift:1293–1310), it does not fall back to the last user
message when the composer is empty, so with an empty composer it silently does
nothing. Fix: reuse `dispatchTo`'s fallback and skip providers whose key is
missing.

---

## Area verdicts (scope items)

- **1. Build health:** PASS (see §0).
- **2. Chat + agent loop:** FORGE_MCP_CALL parsing (AppState.swift:2328–2456)
  is SOUND — four parser shapes incl. the display-format re-parse, brace-depth
  JSON scanner handles strings/escapes; `handleMCPToolRequestIfNeeded` /
  `continueAfterMCPToolResult` pair begin/end correctly and the depth cap is the
  loop bound. The streaming state machine is SOUND on every send() path;
  the sole unpaired `beginStreaming` is finding **#1** (dispatchToAgent, all
  three backends). Local fan-out branch (AppState.swift:1170–1239) pairs
  correctly via `onComplete`.
- **3. Inference lifecycle:** MLX load dedup/generation logic SOUND; GGUF path
  is finding **#2**; generation cleanup findings **#4, #5**; MLXGate usage
  correct — no nested `withTurn` inside a turn anywhere in the engine or server
  (loads and generations each take exactly one turn; `shutdown`/purge take
  their own turns after tasks drain).
- **4. Local API server:** receive/timeout path is finding **#3**. Error
  responses SOUND (guard-fail 4xx/5xx before the head; post-head SSE errors are
  emitted as data events + `[DONE]`, ForgeServer.swift:428–438). Connection
  cleanup SOUND apart from #3: `accept` cancels after `route` returns on both
  success and throw (ForgeServer.swift:147–157). Host/Origin enforcement fails
  closed (ForgeServer.swift:190–207).
- **5. Previously-reported defects:**
  (a) **CONFIRMED** — finding #1 (dispatchToAgent never calls endStreaming).
  (b) **CONFIRMED** — finding #2: the GGUF progress callback has only the
  key-membership check (InferenceEngine.swift:325–329); unlike the MLX path
  there is no `loadGenerations` bookkeeping behind it, so stale/duplicate loads
  corrupt progress and can resurrect unloaded models.
  (c) **CONFIRMED** — finding #3: the timeout throws, but the task group must
  await the receive child, whose continuation is only resumed by an
  `NWConnection` callback that never fires for an idle socket; the connection
  is never cancelled.
- **6. Persistence + settings round-trip:** SOUND (finding #9 is a
  corruption-edge-case note, not a round-trip defect).
- **7. Quick pass:** ChatView.swift — no crash-on-nil or leaked tasks; finding
  #10. MCP.swift — finding #6; `ensureConnected`'s 45 s poll and `readMessage`'s
  `Thread.sleep` polling are inefficient but bounded and off-main.
  HeadlessLauncher.swift — SOUND: pure command-string composer, never launches
  a process, all UserDefaults reads defaulted, validation gates dangerous flags.

## SUMMARY

- **BLOCKER:** 0
- **BUG:** 6 (findings 1–6)
- **MINOR:** 4 (findings 7–10)

Recommended order of fixing: **#1** (stuck streaming UI on the flagship agent
feature, one-line fix) → **#3** (server resource leak) → **#2** (GGUF load
races) → **#4 + #5** (engine accounting, small paired fixes) → **#6** (MCP
stdio serialization). The MINOR items are safe to defer.
