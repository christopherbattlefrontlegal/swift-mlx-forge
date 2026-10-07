# Rivet in Forge

This directory vendors the browser frontend from Ironclad Rivet:

- Repository: https://github.com/Ironclad/rivet
- Upstream revision: `7cdd13a1beec16d86004768da4866500d259647a`
- Revision date: 2026-05-13
- License: MIT (see `LICENSE`)

Forge-specific build changes:

1. Vite's base path is `/rivet/`, where Forge serves the compiled frontend.
2. When loaded from that path, Rivet's default OpenAI-compatible endpoint is
   Forge's same-origin `/v1/chat/completions` route.

## Canvas usability changes (2026-09-29)

Goal: a non-coder starts from "which AI model?" and never types a model id,
endpoint, or API key on the canvas.

- **Forge is the model gateway.** `GET /v1/models` lists local models plus every
  cloud model Forge has a key for, under provider-prefixed ids (`openai/…`,
  `anthropic/…`, `xai/…`, `openrouter/…`). `/v1/chat/completions` forwards those
  ids to the provider with the key stored in Forge (`ForgeServer.handleCloudChat`).
- **Right-click → Add AI Model** (`useForgeAiModelMenu.ts`): provider → model from
  that live list; drops a Chat block preset to the model.
- **Chat block model dropdown** is the same live list inside Forge
  (`ChatNode.getEditors`, `core/src/utils/forgeModels.ts`); new Chat blocks
  default to the loaded local model instead of `gpt-5`.
- **Add Block categories** carry plain-language hover descriptions.
- **Tabs renamed** with hover explanations: Prompt Designer → Prompt Lab, Trivet
  Tests → Forge Tests, Chat Viewer → Conversations, Data Studio → Data Sets.
- **Discord links removed** (start page, project bar, help, community overlay).

Not done yet: tool/plugin blocks beyond the existing MCP group, a Python block,
hiding advanced Chat settings (headers, endpoint) behind one disclosure.

The Tauri shell and prebuilt sidecar executables are omitted because Forge embeds
Rivet's browser application in WebKit. The full browser application source and
the workspace packages needed to build it are retained here.
