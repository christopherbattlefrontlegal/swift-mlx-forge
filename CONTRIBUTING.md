# Contributing

Thanks for working on Forge.

## Development Loop

Use the normal SwiftPM flow:

```sh
swift build
./scripts/security-check.sh
./scripts/build-app.sh
```

Before opening a pull request:

- Keep model weights, app bundles, `.build`, and local configuration out of git.
- Run `swift build`.
- Run `./scripts/security-check.sh`.
- If you touch the app bundle or signing path, run `./scripts/build-app.sh`.
- Keep App Store-safe behavior intact for `Sources/mlx-forge`.

## Security Boundaries

Forge's macOS app target must not spawn external commands. Headless workflows should remain command composition only.

The local API server must remain loopback-only and must not use wildcard CORS.

MCP support in the sandboxed app should use HTTP/SSE. Stdio MCP process launching belongs outside the App Store-safe app.

## Models

Do not commit model files, tokenizer caches, or generated Hugging Face cache directories. Put local models under ignored paths or add them through the app.

