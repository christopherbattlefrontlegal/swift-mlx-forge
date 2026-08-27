# Forge 2.1.0 — MCP everywhere, Media Studio, live catalogs

Forge 2.1.0 makes `mcp.json` the single source of truth for MCP servers,
teaches local models the native tool-call wire formats they were trained on,
and adds the Media Studio pane plus live cloud model catalogs.

## Changes

- **No built-in commander.** The built-in `forge-commander` fallback server and
  its granted-workspace bookmarks are gone. Every MCP server — Desktop
  Commander, memory graph, sequential-thinking, anything else — is declared in
  `mcp.json`; trust fingerprints still gate enablement.
- **Native local tool calling.** Hermes-style JSON tool_call tags and Qwen
  XML function/parameter blocks are now parsed from visible answer text, the
  chat template sniffer picks the wire format at load time, and each tool's
  argument schema rides along in the system prompt so local models can see
  parameters like `offset`.
- **Tool-chain continuity.** Executed MCP results replay into conversation
  history, and bare-JSON turns whose keys match the previous call's schema are
  recovered as tool calls instead of silently ending the agent loop.
- **Media Studio.** Music playback pane with Apple Music transport, EQ-off
  control, and a model tournament.
- **Live cloud catalogs.** Current model lists for every cloud provider,
  including OpenRouter's current Grok slug.
- **macOS 27 support.** Tab picker for the workbench plus catalog tests.
- **Reasoning fixes.** Text-tagged reasoning is classified correctly and
  in-flight API turns cancel cleanly.

## Install

Forge 2.1.0 is a source release. It does not include model weights or an
unnotarized binary.

```sh
git clone https://github.com/christopherbattlefrontlegal/swift-mlx-forge.git
cd swift-mlx-forge
git checkout v2.1.0
./scripts/install-forge-app.sh
```

Requirements: Apple Silicon, macOS 26 or newer, and Swift 6.2 or newer. Node.js is
needed only when an embedded web bundle must be rebuilt.

## Verification performed

- Release Swift build and developer security gate via `scripts/build-app.sh`
- Launch verification of the local `Forge.app` with MCP servers connected
