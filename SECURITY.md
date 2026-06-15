# Security Policy

## Supported Versions

This repository is pre-1.0. Security fixes land on `main` unless a release branch is explicitly created.

## Reporting a Vulnerability

Please do not open a public issue for an active vulnerability. Contact the maintainers privately first, then coordinate disclosure.

If you are running a local fork, include:

- Commit hash.
- macOS version.
- Whether the local API server was enabled.
- Whether MCP servers were configured.
- Exact reproduction steps.

## Current Security Model

Forge is a local-first macOS app. The primary boundaries are:

- Local model files stay on the user's machine.
- API keys are stored in macOS Keychain.
- The OpenAI-compatible server binds to loopback only.
- The server enforces Host and Origin checks and does not use wildcard CORS.
- The App Store-safe Forge target does not spawn external processes.
- MCP stdio entries are not launched by the sandboxed app.

Run the static regression check:

```sh
./scripts/security-check.sh
```

