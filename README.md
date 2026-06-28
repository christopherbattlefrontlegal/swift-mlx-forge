# Forge

SwiftPM package name: `forge_swift_open_source`

Forge is a native macOS app and SwiftPM workspace for running local language models on Apple Silicon with Swift, MLX, and an in-process GGUF backend.

Bring your own models — Qwen, GLM, Granite, IQuest, or any MLX-community or GGUF weights you keep on disk. Forge scans folders you point it at; it does not ship weights in this repo.

The goal is a usable local model workbench:

- Native SwiftUI chat interface for local MLX models.
- GGUF model discovery and chat through `LLM.swift`.
- Multiple loaded local models with explicit load, unload, and stop controls.
- Chat-template sniffing: thinking toggle, repetition penalty, KV cache, and sampling defaults tuned for real MLX models.
- Named system-prompt presets — the inspector shows which preset (or library file) is actually loaded, not just a word count.
- Optional cloud providers (Anthropic, OpenAI, OpenRouter) with Keychain-backed API keys.
- Loopback OpenAI-compatible API server for local agent tools.
- App Store-safe MCP configuration for HTTP/SSE servers.
- Headless command cheat sheet that composes commands for the operator to run manually.

Forge does not ship model weights in this repository.

## Requirements

- macOS 26+ (tested on macOS 27 beta / Golden Gate) with Swift 6.2+.
- Apple Silicon Mac.
- Xcode command line tools or Xcode with Swift 6.
- SwiftPM can resolve all dependencies directly from public git sources.
- Optional: if you need local source overrides, use `swift package edit mlx-swift-lm`.

## Build

From the repository root:

```sh
swift build
```

Run the app locally:

```sh
swift run mlx-forge
```

Install a signed `.app` bundle (recommended for daily use):

```sh
./scripts/build-app.sh /Applications
open /Applications/Forge.app
```

## Run

```sh
open /Applications/Forge.app
# or
open ./Forge.app
```

For command-line experimentation, SwiftPM also builds:

- `mlx-runtime`
- `mlx-studio`
- `mlx-forge`

## Models

Forge scans default locations plus any folders you add in **Settings → Model directories**. Point it at a parent folder or a `mlx-community` cache — it discovers MLX and GGUF trees recursively.

Example layout (your paths will differ):

```text
/Volumes/VAULT/machine/models/
/Volumes/VAULT/machine/models/mlx-community/
  Qwen3-8B-4bit/
  glm-4-9b-4bit/
  granite-3.3-8b-instruct-4bit/
```

Keep model files outside git. Ignored weight formats in the repo include:

- `.safetensors`
- `.gguf`
- `.mlx`
- `.bin`
- `.onnx`
- `.pt`
- `.pth`

Use the app's model browser or user-selected folders to add local models on your machine.

## System prompt presets

In the tuning inspector **System Prompt** section:

- Pick a saved preset from the bookmark menu — the active preset name appears in ember next to the word count.
- Save the current prompt as a named preset; saving also marks it active.
- Load prompts from external folders via the chat toolbar library; the file name shows as the loaded source.
- Manual edits switch the label to **Custom** until text matches a preset again.

## Roadmap: Apple on-device AI (macOS 27+)

Forge today runs MLX and GGUF directly. Apple's macOS 27 stack (Core AI `.aimodel` artifacts, Foundation Models `LanguageModelSession`) is the direction for a unified executor bridge — see [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) and [coreai-models](https://github.com/apple/coreai-models). MLXFoundationModels integration will land when it ships in the upstream MLX Swift LM package.

## MCP

The App Store-safe MCP path is HTTP/SSE:

- HTTPS MCP servers are allowed.
- Plain HTTP is allowed only on loopback: `127.0.0.1`, `localhost`, or `::1`.
- Stdio MCP entries stay idle at launch and can be checked manually from the MCP UI in developer builds.

Forge reads MCP server configuration from the local `mcp.json` in the project working directory.
Run with a working directory that is your repo clone so Forge and the headless helper use that file only.
Use `mcp.example.json` as a safe template before adding your own local server paths.

## Local API Server

Forge can expose a local OpenAI-compatible API server on loopback. The server:

- Binds only to `127.0.0.1`.
- Enforces a Host allowlist.
- Rejects cross-origin browser requests.
- Does not emit wildcard CORS.

Run a build before publishing changes:

```sh
swift build
```

## App Store Notes

This open-source snapshot excludes App Store submission assets. Local signing and App Store packaging workflows are maintained in a private/internal branch or repo.

## Repository Hygiene

This public repository intentionally excludes:

- SwiftPM build products.
- App bundles.
- `.DS_Store` files.
- Local agent/editor settings.
- Model weights and tokenizer caches.

## License

MIT. See `LICENSE`.
