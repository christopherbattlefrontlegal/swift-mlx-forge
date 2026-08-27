# Forge 2.1.1 — Silent agent-loop death fixed

Forge 2.1.1 closes the failure mode where a local model stalled after a
large tool result and the agent loop ended with no visible error.

## Fixes

- **Empty mid-chain turns are recovered.** When a turn in the middle of a
  tool chain comes back completely empty (a stalled model, usually right
  after a very large tool result), Forge now hands the problem back to the
  model with a re-send nudge, bounded by the existing three-retry limit,
  instead of silently ending the run. Previously only turns containing a
  recognizable (but malformed) call shape were recovered.
- **Replay contract test corrected.** The chat-history sanitization test now
  asserts the 2.1.0 contract: executed MCP results replay into model history
  as user turns; status noise stays hidden. Full suite green (51 tests).

## Install

Forge 2.1.1 is a source release. It does not include model weights or an
unnotarized binary.

```sh
git clone https://github.com/christopherbattlefrontlegal/swift-mlx-forge.git
cd swift-mlx-forge
git checkout v2.1.1
./scripts/install-forge-app.sh
```

Requirements: Apple Silicon, macOS 26 or newer, and Swift 6.2 or newer. Node.js is
needed only when an embedded web bundle must be rebuilt.

## Verification performed

- 51 Swift tests, 0 failures
- Release Swift build and developer security gate via `scripts/build-app.sh`
- Launch verification of the local `Forge.app` with MCP servers connected
