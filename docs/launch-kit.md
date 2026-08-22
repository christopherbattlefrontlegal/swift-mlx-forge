# Forge 2.0 launch kit

Use this copy for GitHub, Hacker News, Reddit, Product Hunt, and social posts.
Forge 2.0 is source-installable; do not describe it as a notarized binary download.

## Positioning

**Forge is a native macOS workbench for local Apple Silicon models—with adjustable
reasoning, a visual agent graph, MCP, and an OpenAI-compatible API.**

## Show HN

### Title

Show HN: Forge 2 – Native MLX/GGUF workbench with visual agent graphs for macOS

### Body

Hi HN — I built Forge 2, an MIT-licensed native macOS workbench for running local
models on Apple Silicon.

The app runs MLX and in-process GGUF models, discovers checkpoints directly from
folders on disk, and exposes a loopback OpenAI-compatible API. Version 2 adds a
customized Rivet visual graph beside the native Chat workspace, first-class Inkling
Small chat-template/reasoning-effort support, updated Qwen 3.5/3.6 paths, and prompt
drafts with explicit Save/Revert behavior.

There is no Electron shell and no required Python inference server. The app is SwiftUI;
MLX and llama.cpp run in process. Model weights are not included.

The current release is source-installable on Apple Silicon with macOS 26+ and Swift
6.2+. A public binary will wait for Developer ID signing and notarization.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

I would especially value feedback on model compatibility, graph onboarding, and the
OpenAI-compatible API surface.

## Reddit: r/LocalLLaMA

### Title

Forge 2: native MLX/GGUF Mac app with Inkling reasoning controls and visual workflows

### Post

I have released Forge 2, an open-source SwiftUI workbench for local models on Apple
Silicon.

- MLX and in-process GGUF/llama.cpp
- local checkpoint discovery and Hugging Face downloads
- Inkling Small Jinja/tiktoken support with adjustable reasoning effort
- customized Rivet visual agent graph
- Qwen 3.5/3.6 runtime work
- MCP and a loopback OpenAI-compatible API
- explicit system-prompt Save/Revert workflow

It is source-installable today (macOS 26+, Swift 6.2+); model weights are not bundled.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

## Reddit: r/macapps

### Title

Forge 2 is a native Mac workbench for local AI models and visual agent workflows

### Post

Forge 2 is an MIT-licensed SwiftUI app for running local MLX and GGUF models on Apple
Silicon. It combines native chat and tuning controls with a Forge-themed visual graph,
local model discovery, MCP tools, and a local OpenAI-compatible endpoint.

The release is source-installable while public notarization is still pending:
https://github.com/christopherbattlefrontlegal/swift-mlx-forge

## Reddit: r/swift

### Title

Forge 2: a SwiftUI + MLX local-model workbench with an embedded visual graph

### Post

Forge 2 runs MLX and vendored llama.cpp inference in process inside a native SwiftUI
macOS app. The new release embeds a customized MIT-licensed Rivet canvas, supports
checkpoint-specific Inkling reasoning controls, and serves loaded models through a
loopback OpenAI-compatible API.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

## Product Hunt

### Tagline

Native local-model workbench and visual agent graph for Apple Silicon

### Description

Run MLX and GGUF models, tune model-specific reasoning, build visual workflows, use
MCP tools, and expose a loopback OpenAI-compatible API from one native Mac app.

### Maker comment

I built Forge because I wanted local model work on a Mac to feel like a real native
developer tool. Forge 2 adds the missing visual layer: a customized Rivet graph that
runs beside native Chat and targets Forge's local model server. It also handles the
unusual parts of newer checkpoints, including Inkling Small's Jinja template,
`tiktoken` tokenizer, and continuous reasoning-effort scale.

Forge is MIT licensed, brings no model weights, and is source-installable today.
Feedback on graph UX and model compatibility is very welcome.

## X / Bluesky thread

1. Forge 2 is out: a native macOS workbench for local Apple Silicon models. SwiftUI,
   MLX, in-process GGUF, MCP, and an OpenAI-compatible loopback API.
2. New in 2.0: Forge Graph—a customized Rivet canvas for visual model/tool workflows,
   embedded beside native Chat.
3. Inkling Small gets its actual checkpoint behavior: Jinja chat template, `tiktoken`
   tokenizer, and adjustable None → Max reasoning effort.
4. Prompt editing is explicit now: draft, clear, Save, or Revert. Qwen 3.5/3.6 support
   also received a substantial runtime update.
5. MIT licensed and source-installable today. Repo:
   https://github.com/christopherbattlefrontlegal/swift-mlx-forge

## Launch checklist

- [x] Rewrite README around Forge 2 differentiators
- [x] Add product visual and social preview
- [x] Publish complete 2.0 release notes
- [x] Update project site to Forge 2
- [ ] Publish GitHub release and tag `v2.0.0`
- [ ] Post Show HN after the release URL is live
- [ ] Post to relevant subreddits, following each community's current rules
- [ ] Publish a short graph demo clip
- [ ] Convert launch feedback into focused GitHub issues

## Claim boundaries

- Say: public source, MIT licensed, source-installable, Apple Silicon, SwiftUI, MLX,
  in-process GGUF, customized Rivet graph, MCP, local-first, optional cloud providers.
- Do not say: notarized binary, App Store release, bundled weights, universal Intel
  support, or complete OpenAI API compatibility.
