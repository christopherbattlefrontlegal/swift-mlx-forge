# Research: Memory-Mapped & Lazy Weight Loading for Forge

**Date:** 2026-06-10 · **Status:** RESEARCH ONLY — nothing applied. Audit before acting.
**Question:** When Forge loads a model, can we mmap the safetensors instead of copy-reading
them, and/or materialize weights lazily — and what would each buy us?

---

## 1. What Forge does today (traced, not guessed)

Full call chain, verified against the sources on this drive:

```
InferenceEngine.swift:~103   LLMModelFactory.shared.loadContainer(...)
  └─ mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift:564   loadWeights(...)
       └─ mlx-swift-lm/Libraries/MLXLMCommon/Load.swift:14-59
            ├─ :22-34  enumerate *.safetensors, loadArraysAndMetadata(url:) per shard
            ├─ :40-51  quantize(model:) if config says so
            ├─ :56     model.update(parameters:verify:)
            └─ :58     eval(model)            ← THE eager-materialization line
                 └─ mlx-swift/Source/MLX/Transforms+Eval.swift:18  mlx_eval(...)
```

**Verdict 1 — mmap: NO.** `mlx_load_safetensors` takes a path; the C++ core opens it
with plain `open()`/`read()` (fast raw-fd reads since MLX PR #1330, ~6.9 GB/s on
M2 Ultra). Bytes are read into MLX's Metal-shared allocator buffers. No `mmap`
anywhere in the load path.

**Verdict 2 — laziness: HALF.** MLX arrays returned by `loadArraysAndMetadata` are
*lazy graph nodes* — no tensor bytes are read until eval (confirmed by MLX maintainers,
mlx discussion #1292). But `Load.swift:58` calls `eval(model)` on **everything at
once**, so by the time `loadContainer` returns, the entire model is materialized.
The laziness exists; our library layer immediately defeats it.

**Key leverage fact:** `mlx-swift-lm` is a **local path dependency**
(`Package.swift:30 — .package(path: "../mlx-swift-lm")`). `Load.swift:58` is our code
to change. No fork of anything remote is required for the lazy-eval options.
(`mlx-swift` itself — the C++ core — IS a remote pin, 0.31.4, latest as of June 2026.)

---

## 2. What upstream knows (so we don't re-learn it the hard way)

- **MLX maintainers have explicitly declined mmap** (discussion #615, awni): for
  models that fit in RAM, lazy load + fast read is nearly as good; for models that
  don't fit, mmap paging is catastrophic.
- **A working mmap prototype exists** (antbob's fork, `mmap-prototype` branch):
  mmaps safetensors + wraps pages with `newBufferWithBytesNoCopy`. Two findings:
  1. **safetensors tensor offsets are not page-aligned**, so true zero-copy requires
     repacking the weight files (a new on-disk format, like GGUF's aligned blob).
  2. **Overcommit is pathological:** 70 GB model on a 64 GB machine ran at
     **0.025 tok/s** vs ~6 tok/s for a quant that fits — 240× slower. The kernel
     evicts clean file-backed pages first, so generation re-faults from SSD per token.
- **llama.cpp's trick** (the reason "Ollama loads instantly"): GGUF is one file with
  32-byte-aligned tensor data; `llama-mmap.cpp` mmaps it, `ggml-metal-device.m`
  rounds the pointer down to a page boundary and wraps it with
  `MTLBuffer(bytesNoCopy:, storageModeShared)`. Zero copy on unified memory.
  Honest trade-offs: cold load is still disk-bound (the "instant" load is the
  *second* one, from warm page cache); first-token latency absorbs page faults;
  pages are evictable under pressure unless mlock'd.
- **LM Studio's MLX engine does none of this** — it calls mlx-lm `load()` with
  `lazy=False` (fully eager, same as us). The most prominent commercial MLX app
  ships the plain path we already have.
- **mlx-lm's `lazy=True`** is just "skip the final `mx.eval`" — deferred read,
  not mmap. It's the supported pattern for bounding transient memory (it's how
  people quantize 400B models on small machines).
- Watch: mlx issue **#2878** (open feature request for streaming/mmap IO) and
  issue **#3329** (SIGSEGV when `mx.compile` fused kernels met lazy arrays with a
  null MTLBuffer — caution sign for "defer eval into the forward pass").

---

## 3. Options for Forge

### Option A — True mmap → MTLBuffer (the llama.cpp mechanism)
**What:** Fork mlx-swift's C++ core allocator + repack safetensors into a
page-aligned container format.
**Buys:** Near-instant warm loads; zero transient copy.
**Costs:** Forking a fast-moving C++ core we currently consume as a clean version
pin; inventing/maintaining a weight repack format; known crash interactions
(#3329); upstream is philosophically against it so we'd carry the patch forever.
**Verdict: NO.** Wrong trade for a one-person App Store app. This is the
Osaurus-style "carry a custom runtime fork" path, and even they didn't do mmap.

### Option B — Chunked lazy eval in `Load.swift` (RECOMMENDED)
**What:** In our local `mlx-swift-lm/Libraries/MLXLMCommon/Load.swift`, replace the
single `eval(model)` (line 58) with **per-shard (or per-layer) evaluation**: load
shard → update params → `eval(thatShard'sArrays)` → drop the dict → next shard.
**Buys:**
- Caps **transient peak memory** at ~(materialized-so-far + one shard) instead of
  (all lazy dicts + full materialization at once). On multi-shard models this
  removes the load-time memory spike — the thing that matters when a 60-70 GB
  daily driver loads while other apps are using RAM.
- Enables an honest **load progress bar** (per-shard progress instead of the
  current indeterminate hang between "downloaded" and "ready").
- Zero new dependencies, ~20 lines, in code we already own locally.
**Costs:** Wall-clock load time roughly unchanged (still read-bound at ~7 GB/s);
slight refactor risk in a file the VLM factory also uses — must keep
`quantize(model:)` semantics intact (quantization consumes lazy arrays per-layer
already, which is exactly why this pattern is upstream-blessed).
**Verdict: YES — this is the real, supported win.**

### Option C — Full-lazy load (defer ALL eval to first token)
**What:** Skip `eval(model)` entirely; weights materialize during the first
forward pass.
**Buys:** "Load" returns in milliseconds — great demo.
**Costs:** First token absorbs the entire multi-GB read (TTFT balloons by seconds);
interacts badly with compiled paths (#3329 class); file handles/lifetime get subtle.
**Verdict: NO as default.** Possibly later as an opt-in "fast switch" mode, after
Option B is proven.

### Option D — Post-load residency hardening (companion to B)
**What:** Use mlx-swift's wired-memory utilities (`WiredMemoryUtils` /
`MLX.GPU` wired limit, shipped in mlx-swift 0.30.6+, present in our 0.31.4) so a
loaded daily-driver model can't be evicted into mid-generation stalls.
**Buys:** Fixes the failure mode that is mmap's main *downside*, without mmap.
Pairs with the existing idle/unload story and the MLXGate.
**Costs:** Wiring memory is a real commitment of RAM — must stay behind a setting,
and must respect App Store sandbox behavior (it's just MLX API, no entitlement).
**Verdict: YES, behind a Tuning-panel toggle, after B.**

---

## 4. Proposed implementation sketch (NOT APPLIED — for audit)

In `mlx-swift-lm/Libraries/MLXLMCommon/Load.swift`, the core of Option B:

```swift
// Today (simplified):
var weights = [String: MLXArray]()
for url in shardURLs {
    let (w, _) = try loadArraysAndMetadata(url: url)
    weights.merge(w) { a, _ in a }
}
// quantize(model:), model.update(parameters:), then:
eval(model)                                  // ← all shards at once

// Proposed:
for (index, url) in shardURLs.enumerated() {
    let (w, _) = try loadArraysAndMetadata(url: url)   // lazy nodes
    weights.merge(w) { a, _ in a }
    eval(Array(w.values))                    // materialize THIS shard only
    progress?(Double(index + 1) / Double(shardURLs.count))
}
// quantize + update + a final cheap eval(model) as a correctness backstop
// (already-materialized arrays are no-ops to eval).
```

Open questions for the audit (deliberately unresolved here):
1. Quantized models: `quantize(model:)` runs *after* the merge today — per-shard
   eval materializes **fp16 source arrays** that quantization then replaces.
   For quantized loads the eval should arguably move *after* quantize per-layer,
   or shard-eval should be skipped when a quant config exists. Needs a decision.
2. The same Load.swift serves MLXVLM — verify vision towers tolerate the ordering.
3. Whether to expose a per-shard progress callback up through `loadContainer`
   (Forge's `loadingModels[id]` is already plumbed for exactly this).

## 5. Validation plan (when applied)

1. Cold-load Qwen 3.5 122B-A10B with Activity Monitor + `Memory.peakMemory`
   instrumentation: record peak RSS and wall-clock, before vs after.
2. Same with the smallest multi-shard model (fast iteration).
3. Generation correctness: fixed-seed prompt before/after, identical output.
4. Quantized + VLM model load each verified (open questions 1-2).
5. `scripts/security-check.sh` + full build, as always.

## 6. Bottom line

- **mmap is the wrong tool for Forge**: upstream-rejected, needs a C++ fork plus a
  repacked weight format, and its one real advantage (instant warm loads) matters
  least on a machine that keeps one model resident long-term.
- **Lazy loading is already half-built into MLX and we own the line that defeats
  it.** Chunked eval (Option B) + wired residency (Option D) gets the memory-spike
  and stall benefits with ~20 lines in locally-controlled code and no forks.

### Sources
- mlx discussion #615 (maintainer position + antbob prototype numbers) · mlx #1292
  (lazy-load semantics, authoritative) · mlx PR #1330 (fast read path) · mlx PR #3371
  (streaming loader, rejected) · mlx #2878 (open streaming request) · mlx #3329
  (compile × lazy crash) · llama.cpp `src/llama-mmap.cpp` +
  `ggml/src/ggml-metal/ggml-metal-device.m` (bytesNoCopy mechanism) ·
  lmstudio-ai/mlx-engine `model_kit.py` (eager load) · mlx-lm `utils.py`
  (`lazy=` semantics) · justine.lol/mmap (history + trade-offs) ·
  local trace: `mlx-swift-lm/Libraries/MLXLMCommon/Load.swift:14-59`,
  `mlx-swift/Source/MLX/IO.swift:155-176`, `Transforms+Eval.swift:15-20`.
