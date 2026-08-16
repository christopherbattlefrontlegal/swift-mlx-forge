# Rivet in Forge

This directory vendors the browser frontend from Ironclad Rivet:

- Repository: https://github.com/Ironclad/rivet
- Upstream revision: `7cdd13a1beec16d86004768da4866500d259647a`
- Revision date: 2026-05-13
- License: MIT (see `LICENSE`)

Forge-specific changes are deliberately small:

1. Vite's base path is `/rivet/`, where Forge serves the compiled frontend.
2. When loaded from that path, Rivet's default OpenAI-compatible endpoint is
   Forge's same-origin `/v1/chat/completions` route.

The Tauri shell and prebuilt sidecar executables are omitted because Forge embeds
Rivet's browser application in WebKit. The full browser application source and
the workspace packages needed to build it are retained here.
