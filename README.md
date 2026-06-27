# Forge

SwiftPM package name: `forge_swift_open_source`

Forge is a native macOS app and SwiftPM workspace for running local language models on Apple Silicon with Swift, MLX, and an in-process GGUF backend.

The goal is a usable local model workbench:

- Native SwiftUI chat interface for local MLX models.
- GGUF model discovery and chat through `LLM.swift`.
- Multiple loaded local models with explicit load, unload, and stop controls.
- Optional Anthropic API provider using macOS Keychain storage for the API key.
- Loopback OpenAI-compatible API server for local agent tools.
- App Store-safe MCP configuration for HTTP/SSE servers.
- Headless command cheat sheet that composes commands for the operator to run manually.

Forge does not ship model weights in this repository.

## Requirements

- macOS 26 or newer with Swift 6.2+.
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

## Run

```sh
open ./Forge.app
```

For command-line experimentation, SwiftPM also builds:

- `mlx-runtime`
- `mlx-studio`
- `mlx-forge`

## Models

Forge scans local model folders and user-selected directories. Keep model files outside git.

Ignored model formats include:

- `.safetensors`
- `.gguf`
- `.mlx`
- `.bin`
- `.onnx`
- `.pt`
- `.pth`

Use the app's model browser or user-selected folders to add local models on your machine.

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
