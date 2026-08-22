# Forge 2.0.0 — Inkling reasoning and Forge Graph

Forge 2 turns the native local-model workbench into a visual agent workspace while
keeping inference, model discovery, and project data on your Mac by default.

## Highlights

- **Inkling Small support.** Load local MXFP4/NVFP4 checkpoints directly from disk,
  including `tiktoken` tokenizer models and the checkpoint's Jinja chat template.
  Forge maps None, Minimal, Low, Medium, High, and Max into Inkling's reasoning-effort
  scale instead of flattening the model's thinking controls.
- **Forge Graph.** A customized, Forge-themed build of the MIT-licensed Rivet canvas is
  embedded beside Chat. Build visual workflows, connect prompts/models/tools/outputs,
  and target Forge's loopback OpenAI-compatible server.
- **Qwen runtime work.** Updated Qwen 3.5/3.6 paths, including multi-token prediction
  support and model-loading compatibility work.
- **Prompt drafts that behave like drafts.** The tuning inspector now shows Saved or
  Unsaved state and exposes explicit Save/Revert controls. Clearing a prompt can be
  saved intentionally to restore model-default behavior.
- **Modern native chrome.** The workbench switcher, API/memory status, and tuning action
  use a grouped macOS 27 toolbar and system glass treatments.
- **Dependency hardening.** Forge's Rivet build is scoped to the three workspaces it
  ships, removes unused server/community/CLI dependency trees, and updates critical
  browser/runtime packages.

## Install

Forge 2.0.0 is a source release. It does not include model weights or an unnotarized
binary.

```sh
git clone https://github.com/christopherbattlefrontlegal/swift-mlx-forge.git
cd swift-mlx-forge
./scripts/install-forge-app.sh
```

Requirements: Apple Silicon, macOS 26 or newer, and Swift 6.2 or newer. Node.js is
needed only when an embedded web bundle must be rebuilt.

## Verification performed

- 29 Swift tests
- Release Swift build and developer security gate
- Signed local `Forge.app` assembly
- Rivet core, Trivet, and browser production builds
- Rendered Chat, prompt controls, and Forge Graph inspection in the packaged app

## Distribution note

The local installer signs the app for the Mac that builds it. A drag-and-drop binary
for other Macs will follow Developer ID signing and Apple notarization.
