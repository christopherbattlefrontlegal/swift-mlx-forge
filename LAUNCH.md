# Forge Launch Kit

Use this copy anywhere GitHub lets the project speak for itself: repository description,
release notes, pinned issue, README snippets, and community posts.

## One-line position

Forge is a native macOS workbench for Apple Silicon local LLMs: MLX plus in-process
GGUF, adjustable reasoning, a visual agent graph, MCP, and a loopback OpenAI-compatible API.

## Short pitch

Forge is for Mac users who keep models on disk and want local inference to feel
native. It scans MLX and GGUF model folders, loads and unloads models deliberately,
keeps optional provider keys in Keychain, exposes prompt and sampling controls, and
can serve a local OpenAI-compatible endpoint for agent tools.

## GitHub repository description

Native macOS workbench for Apple Silicon local LLMs: SwiftUI, MLX, GGUF, visual
agent graphs, adjustable reasoning, MCP, and an OpenAI-compatible API.

## Suggested topics

`mlx`, `mlx-swift`, `gguf`, `llama-cpp`, `apple-silicon`, `macos`, `swift`,
`swiftui`, `local-llm`, `local-ai`, `on-device-ai`, `model-context-protocol`,
`mcp`, `openai-compatible`, `ai-workbench`, `macos-app`

## Release summary

Forge v2.0 is source-installable: clone the public MIT repo, run
`./scripts/install-forge-app.sh`, and point the app at your local MLX or GGUF model
folders. The installer builds the release product, bundles the Metal library,
packages Forge Graph, the design prompt tool, and llama.cpp framework, ad-hoc signs locally,
installs `/Applications/Forge.app`, and opens it.

Public binary downloads are intentionally not attached until the app is signed with
a Developer ID Application certificate and notarized.

## Community post

Forge 2.0 is public: a native macOS workbench for Apple Silicon local LLMs. It runs
MLX and in-process GGUF models side by side, supports Inkling Small reasoning effort,
builds workflows on a customized Rivet graph, speaks MCP, and exposes a local
OpenAI-compatible API. MIT licensed. Source-installable today.

## Claim boundaries

- Do say: public, MIT licensed, source-installable, Apple Silicon, MLX, GGUF,
  SwiftUI, local-first, optional cloud providers, Keychain-backed API keys.
- Do not say yet: notarized binary, App Store release, drag-and-drop public
  download, bundled model weights, or zero-build install.
