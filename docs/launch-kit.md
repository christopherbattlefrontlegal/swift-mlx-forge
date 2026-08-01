# swift-mlx-forge Launch Kit

This file contains ready-to-post launch copy for GitHub, Hacker News, Reddit, Product Hunt, and X/Twitter.

---

## 1) README hero rewrite (drop-in)

````markdown
# swift-mlx-forge

**The native macOS workbench for running local Apple Silicon LLMs — with an OpenAI-compatible API.**

Run GGUF/MLX models locally, build reusable prompt workflows, dispatch agents, and expose a local API your existing tooling can call.

![swift-mlx-forge demo](./docs/assets/demo.gif)

## Why people use swift-mlx-forge

- **Native macOS performance** on Apple Silicon (SwiftUI + MLX)
- **Private by default**: local-first workflows on your machine
- **OpenAI-compatible local API** so existing clients work with minimal changes
- **All-in-one workbench**: prompt libraries, MCP, and agent dispatch

## Who this is for

- **Developers** testing and iterating on local LLM apps quickly
- **Power users** who want private offline AI workflows on macOS
- **AI tinkerers** exploring MLX, GGUF, tools, and agent orchestration

## Quickstart (2 minutes)

1. Install the app from [Releases](../../releases)
2. Launch and load a local model
3. Start the local OpenAI-compatible endpoint
4. Send your first request:

```bash
curl http://localhost:PORT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "YOUR_LOCAL_MODEL",
    "messages": [{"role":"user","content":"Hello from local Mac AI"}]
  }'
```

## What makes it different

| Feature | swift-mlx-forge | Typical local UI | API-only runner |
|---|---:|---:|---:|
| Native macOS UX | ✅ | ⚠️ (varies) | ❌ |
| Apple Silicon focus (MLX) | ✅ | ⚠️ | ❌ |
| In-process GGUF workflows | ✅ | ⚠️ | ❌ |
| Prompt library tooling | ✅ | ⚠️ | ❌ |
| MCP + agent dispatch | ✅ | ❌ | ❌ |
| OpenAI-compatible local API | ✅ | ⚠️ | ✅ |

## Benchmarks

See benchmark methodology and results in [`docs/benchmarks.md`](./docs/benchmarks.md).

## Roadmap

- Better model management UX
- Expanded tool integrations
- Performance and memory tuning by model family

Want to contribute? Check [open issues](../../issues) and look for `good first issue`.
````

---

## 2) Show HN launch draft

### Suggested title options

- **Show HN: swift-mlx-forge – Native macOS workbench for local Apple Silicon LLMs**
- **Show HN: Local LLM workbench for macOS (MLX + GGUF + OpenAI-compatible API)**

### Body

Hi HN — I built **swift-mlx-forge**, a native macOS workbench for running local LLMs on Apple Silicon.

It combines:

- SwiftUI native desktop UX
- MLX-focused local inference workflows
- In-process GGUF support
- Prompt libraries
- MCP + agent dispatch
- A local OpenAI-compatible API endpoint

The goal is simple: make local model experimentation on Mac feel fast, private, and production-adjacent for developers.

I’d especially love feedback on:

1. onboarding flow
2. model management UX
3. API compatibility edge cases
4. what’s missing for day-to-day developer use

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

If useful, I can follow up with benchmark details by chip/model and a compatibility matrix.

---

## 3) Reddit post drafts

### A) r/LocalLLaMA

**Title:** Built a native macOS Apple Silicon local LLM workbench (MLX + GGUF + OpenAI-compatible API)

I’ve been building **swift-mlx-forge**: a native macOS app for local LLM workflows on Apple Silicon.

Main pieces:
- SwiftUI app UX
- MLX-oriented runtime
- In-process GGUF workflows
- Prompt library tooling
- MCP + agent dispatch
- Local OpenAI-compatible API

Would love feedback from local-first users:
- Which model workflows matter most?
- What API compatibility issues should I test first?
- What benchmark format is most useful for this community?

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

---

### B) r/macapps

**Title:** New native macOS app for local AI workflows on Apple Silicon

Hey all — I made **swift-mlx-forge**, a native macOS app for running local LLMs on Apple Silicon and exposing a local API.

It’s aimed at private/local-first usage with developer-friendly workflow features like prompt libraries and agent dispatch.

I’d really value macOS UX feedback: performance, ergonomics, and onboarding.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

---

### C) r/swift

**Title:** I built a SwiftUI + MLX macOS workbench for local LLMs

Built and shipped: **swift-mlx-forge**

A native macOS app focused on local Apple Silicon LLM workflows:
- SwiftUI desktop app
- MLX integration
- Local OpenAI-compatible API
- Prompt libraries + agent dispatch

Would love Swift-focused feedback on architecture and performance tradeoffs.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

---

## 4) Product Hunt draft

### Tagline

**Native macOS local LLM workbench for Apple Silicon — with OpenAI-compatible API**

### Short description

Run local GGUF/MLX models, manage prompt workflows, dispatch agents, and expose a local OpenAI-compatible endpoint — all from a native SwiftUI app.

### First comment (maker)

Hey Product Hunt 👋

I built **swift-mlx-forge** to make local LLM development on Apple Silicon feel practical for daily use.

What it does:
- Native macOS UX (SwiftUI)
- MLX + in-process GGUF local workflows
- Prompt libraries
- MCP + agent dispatch
- Local OpenAI-compatible API endpoint

Why I made it:
I wanted a local-first setup that’s private by default, fast to iterate in, and easy to plug into existing developer tooling.

If you try it, I’d love feedback on:
1. onboarding speed
2. model/runtime controls
3. API compatibility
4. top missing feature for your workflow

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

Thanks for checking it out 🙏

---

## 5) X/Twitter launch thread draft

**Post 1/**
I built **swift-mlx-forge**: a native macOS workbench for running local Apple Silicon LLMs.

SwiftUI + MLX + in-process GGUF + local OpenAI-compatible API.

Repo: https://github.com/christopherbattlefrontlegal/swift-mlx-forge

**Post 2/**
Goal: make local model work on Mac feel practical for daily dev.

- private/local-first
- fast iteration loops
- API compatibility with existing clients

**Post 3/**
What’s included right now:
- prompt libraries
- MCP integration points
- agent dispatch workflows
- local endpoint for app/dev tooling

**Post 4/**
If you build with local models on Apple Silicon, I’d love feedback:
- onboarding friction
- model management
- API edge cases
- benchmark expectations

**Post 5/**
If there’s interest, I’ll publish:
- chip-by-chip benchmark breakdown
- compatibility matrix
- “best starter configs” by use case

---

## 6) Optional benchmark post framework

Use this outline for a follow-up blog/GitHub discussion:

1. Hardware + OS + app version
2. Model list + quantization
3. Prompt/test protocol
4. Throughput + latency metrics
5. Memory footprint
6. Failure/instability notes
7. Repro steps/scripts

---

## 7) Quick execution checklist

- [ ] Add demo GIF + screenshots to repo
- [ ] Replace README hero section
- [ ] Publish benchmark doc + methodology
- [ ] Post Show HN
- [ ] Post in 2–3 relevant subreddits (follow each subreddit rules)
- [ ] Launch Product Hunt with maker comment
- [ ] Publish X thread + short demo clip
- [ ] Collect feedback into GitHub issues with labels
