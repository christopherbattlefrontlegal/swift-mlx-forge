# Forge 2.0.1 — Reasoning stream integrity

Forge 2.0.1 fixes reasoning-token separation across local and cloud inference
backends so private model thinking does not contaminate visible answer content.

## Fixes

- **Typed inference streams.** Backends now classify reasoning and answer content
  before deltas reach application state.
- **Correct MLX prompt state.** Forge derives the initial reasoning state from the
  tokenizer and the actual prepared prompt token sequence, including `<think>`,
  `<longcat_think>`, and multi-token thought-channel markers.
- **Native GGUF separation.** The GGUF path uses LLM.swift's distinct thinking and
  response callbacks, correct thinking modes, and serialized template configuration.
- **Provider-native cloud streams.** Anthropic, OpenAI, and OpenRouter reasoning fields
  remain separate from answer content through streaming and persistence.
- **Compatibility parsing stays backend-local.** Incremental tag parsing remains only
  as a model-specific fallback and never receives template-source guesses.

## Install

Forge 2.0.1 is a source release. It does not include model weights or an unnotarized
binary.

```sh
git clone https://github.com/christopherbattlefrontlegal/swift-mlx-forge.git
cd swift-mlx-forge
git checkout v2.0.1
./scripts/install-forge-app.sh
```

Requirements: Apple Silicon, macOS 26 or newer, and Swift 6.2 or newer. Node.js is
needed only when an embedded web bundle must be rebuilt.

## Verification performed

- 40 Swift tests
- Release Swift build and developer security gate
- Strict deep code-signature verification of the local `Forge.app`

## Distribution note

The local installer signs the app for the Mac that builds it. A drag-and-drop binary
for other Macs will follow Developer ID signing and Apple notarization.
