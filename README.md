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

- macOS 14 or newer.
- Apple Silicon Mac.
- Xcode command line tools or Xcode with Swift 6.
- SwiftPM can resolve all dependencies directly from public git sources.
- Optional: if you need local source overrides, use `swift package edit mlx-swift-lm`.

## Build

From the repository root:

```sh
swift build
```

Build the local app bundle:

```sh
./scripts/build-app.sh
```

The bundle is written to:

```sh
./Forge.app
```

The script also runs `scripts/security-check.sh`, bundles the Metal library and llama framework when available, and ad-hoc signs the local app for development use on the current Mac.

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
- Stdio MCP entries are recognized for compatibility but are not launched by Forge.

Forge first checks for `mcp.json` in the current working directory (useful for development), then falls back to
`~/Library/Application Support/Forge/mcp-servers.json`.  
Keep your local MCP configuration in `mcp-servers.json` (portable) and run with a working directory
that is your repo clone for the local `mcp.json` flow.  
Use `mcp.example.json` as a safe template before adding your own local server paths.

## Local API Server

Forge can expose a local OpenAI-compatible API server on loopback. The server:

- Binds only to `127.0.0.1`.
- Enforces a Host allowlist.
- Rejects cross-origin browser requests.
- Does not emit wildcard CORS.

Run the regression check before publishing changes:

```sh
./scripts/security-check.sh
```

## App Store Notes

The `MacAppStore/` folder contains entitlements and submission notes. The local `build-app.sh` output is ad-hoc signed for development only. App Store or TestFlight distribution requires your Apple signing identity, provisioning profile, and App Store Connect workflow.

## Repository Hygiene

This public repository intentionally excludes:

- SwiftPM build products.
- App bundles.
- `.DS_Store` files.
- Local agent/editor settings.
- Model weights and tokenizer caches.

## License

MIT. See `LICENSE`.
