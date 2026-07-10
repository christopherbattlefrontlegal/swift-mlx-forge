# Install Forge

Forge is source-installable today. The GitHub release is source-only until the app is signed with a Developer ID Application certificate and notarized for public binary downloads.

## Requirements

- Apple Silicon Mac.
- macOS 26 or newer.
- Xcode 26 or newer, or any Swift toolchain with Swift 6.2+.
- Node.js/npm for the bundled design-prompt tool that is copied into `Forge.app`.
- Local MLX or GGUF model files. Forge does not ship model weights.

## One Path

```sh
git clone https://github.com/christopherbattlefrontlegal/swift-mlx-forge.git
cd swift-mlx-forge
./scripts/install-forge-app.sh
```

The installer builds the release `mlx-forge` product, compiles the required `mlx.metallib`, builds the embedded design-prompt web bundle if needed, copies the llama.cpp framework into the app bundle, ad-hoc signs the result, installs `/Applications/Forge.app`, and opens it.

## Manual Build

```sh
swift build --product mlx-forge
swift run mlx-forge
```

To build the app bundle without installing it:

```sh
./scripts/build-app.sh
open ./Forge.app
```

## MCP Config

The installed app seeds an empty config at
`~/Library/Application Support/Forge/mcp.json`. A development run from the source
tree may use the ignored repository `mcp.json`; `mcp.example.json` is only a
reference template. New or changed external entries remain disabled until you
explicitly enable and trust their current configuration in Forge.

## Public Binary Status

A public drag-and-drop binary should be signed with a Developer ID Application certificate and notarized before it is attached to a GitHub release. The current local source installer is intentionally ad-hoc signed on the user's Mac.
