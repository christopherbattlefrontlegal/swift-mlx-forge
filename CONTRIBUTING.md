# Contributing

Thanks for working on Forge.

## Development Loop

Use the normal SwiftPM flow:

```sh
swift build --product mlx-forge
swift run mlx-forge
```

Before opening a pull request:

- Keep model weights, app bundles, `.build`, and local configuration out of git.
- Run `swift build --product mlx-forge`.
- Run `./scripts/security-check.sh --developer`.
- Optionally run `swift run mlx-forge` to verify the app entrypoint.
- Keep App Store-safe behavior intact for `Sources/mlx-forge`.

## Security Boundaries

The Mac App Store sandbox profile must not spawn external commands. Developer builds may launch configured stdio MCP servers after the user connects them.

The local API server must remain loopback-only and must not use wildcard CORS.

MCP support in the sandboxed app should use HTTP/SSE. Stdio MCP process launching belongs to the developer build only.

## Models

Do not commit model files, tokenizer caches, or generated Hugging Face cache directories. Put local models under ignored paths or add them through the app.
