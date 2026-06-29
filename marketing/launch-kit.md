# MLX Forge Launch Kit

## One-Line Position

MLX Forge is a native macOS workbench for running local language models on Apple Silicon with Swift, MLX, in-process GGUF, prompt controls, MCP configuration, and a loopback OpenAI-compatible API.

## Short Pitch

MLX Forge is for Mac users who keep models on disk and want local inference to feel native. It scans MLX and GGUF model folders, lets you load and unload models deliberately, exposes prompt and sampling controls, stores optional cloud provider keys in Keychain, and can serve a local OpenAI-compatible endpoint for agent tools.

## Practical Positioning

- Not just a framework: it is a native SwiftUI workbench.
- Not just a chat box: it includes model discovery, tuning controls, prompt preset inspection, MCP configuration, and local API serving.
- Not a cloud relay: the core path is local-first, with optional Anthropic, OpenAI, and OpenRouter integrations.
- Not a model bundle: users bring their own MLX-community or GGUF weights.

## GitHub Description

Native macOS app and SwiftPM workspace for running local language models on Apple Silicon with Swift, MLX, and an in-process GGUF backend.

## Suggested Repository Topics

mlx, mlx-swift, apple-silicon, macos, swiftui, local-llm, gguf, llm-swift, openai-compatible, mcp, ai-workbench

## Social Posts

MLX Forge is public: a native macOS workbench for Apple Silicon local LLMs. MLX plus in-process GGUF, model folder scanning, prompt tuning, MCP configuration, and a loopback OpenAI-compatible API. Built in Swift. Bring your own models.

Most local LLM tooling on Mac is either a framework, a CLI, or a generic wrapper. MLX Forge is the Mac-native workbench: point it at your models, load what you want, tune the chat surface, and hand a local endpoint to your tools.

If you run local models on Apple Silicon and want the app surface to feel like macOS instead of a web panel, try MLX Forge. Native SwiftUI, local-first, MLX and GGUF, optional cloud keys, and agent-friendly loopback serving.

## Website CTA

Star the repo, build the app, point it at your models, and put your Apple Silicon machine to work.

## Important Claim Boundary

As of the current local check, the GitHub repository is public and `origin/main` points at commit `17a7f5aa`. GitHub did not report a formal latest Release object, so launch copy should say "public GitHub repo" unless a GitHub Release is created.
