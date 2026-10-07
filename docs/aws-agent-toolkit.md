# AWS Agent Toolkit in Forge

Installed on September 15, 2026 for `/Volumes/TB4_1TB/swift-mlx-forge`.

## Use it

Open Forge and select a local or cloud chat model. The MCP server list includes:

- `aws-mcp`: the authenticated AWS managed server, using `dev-admin` in `us-east-1`.
- `aws-skills`: two local tools, `list_skills` and `retrieve_skill`, covering 127 unique skills.

Try: **“Find and read the AWS SDK for Swift skill, then summarize how I should configure a service client.”**

The skill catalog is searched on demand. Long skills and references have a `next_offset` field; the model should continue reading until it is null. Retrieval reads files and does not execute scripts. This keeps the entire library out of each prompt while making the complete content accessible to small and large models.

Both servers are enabled in Forge. Existing servers and their configurations were preserved.

## Installed files

- `.agents/skills/`: standard agent skill discovery links.
- `.agents/aws-agent-toolkit/`: upstream files, plugin skills, local index, AWS rules, and provenance manifest.
- `scripts/aws-skills-server.py`: MCP skill reader, launched with `uv`; dependencies are declared and pinned in the script.
- `AGENTS.md` and `CLAUDE.md`: AWS project rules.
- `mcp.json`: project MCP configuration.
- `~/Library/Application Support/Forge/mcp.json`: normal app MCP configuration.
- `~/.local/bin/asm-exec`: upstream runtime secret-reference helper.

The requested repository's `Forge.app` and `/Applications/Forge.app` contain the rebuilt runtime. The external volume must remain mounted for the local skill server and its library.

## Runtime support

Forge now retains instructions returned by MCP initialization and includes them in both its native cloud-tool path and its local-model tool prompt. Instructions are included only while the corresponding server is trusted, connected, and has selected tools. Disabling a server removes its instructions. Failed stdio initialization also closes the partially started process. Local text-tool prompts retain complete descriptions and JSON argument schemas, so clipping cannot remove required API instructions or leave partial schemas.

Forge's existing tool-call parser and execution loop remain the mechanism that executes model requests. The integration has no model-size restriction. Whether a particular model chooses the right skill and completes a task still depends on that model; no inference benchmark across model sizes was performed during this installation.

## Sources and scope

Setup followed the [AWS setup guide](https://raw.githubusercontent.com/aws/agent-toolkit-for-aws/refs/heads/main/setup-instructions/setup.md) and the [custom-agent installation path](https://github.com/aws/agent-toolkit-for-aws#other-agents). The CLI's global wizard targets recognized coding tools; Forge uses its own configuration, so the MCP and skills were installed directly into Forge.

The upstream snapshot is `de9d0249ce33f56929dbf605a9e75773ab381f11` from `aws/agent-toolkit-for-aws`. It includes the skills tree and additional plugin skills. The required `aws-secrets-manager` skill and its `asm-exec` helper were supplied by the already-installed AWS plugin cache because the current upstream repository/catalog does not contain that exact skill. `manifest.json` records the source and SHA-256 of every installed source file. All 104 names from the authenticated remote catalog are present in the 127-skill local index.

AWS plugin hooks written for other agents do not automatically execute in Forge. The installed Secrets Manager skill supplies the handling rules and `asm-exec` helper; this installation does not claim that Claude-specific hooks enforce Forge tool calls.

Existing `dev-admin` authentication was verified and reused. No browser sign-in or credential replacement was necessary. For another profile, authenticate it with AWS, update the space-separated `AWS_MCP_PROXY_PROFILES` value in both MCP files, and re-enable the modified server in Forge. Forge requires renewed trust whenever a server configuration changes.

## Verification

- AWS CLI identity succeeded for `arn:aws:iam::052737073943:user/dev-admin`.
- Authenticated `list-available-skills` returned 104 skills; none are missing locally.
- Forge's actual Swift stdio client initialized both servers: 8 AWS tools and 2 local skill tools.
- The client retrieved the Swift SDK and Secrets Manager skills.
- `aws___run_script` completed an STS `GetCallerIdentity` call; the response's `api_calls` record reported success for that operation and the expected identity.
- Forge's manager accepted the exact configuration fingerprints, exposed all 10 toolkit tools, included the AWS guidance, and removed the skill guidance when that server was disabled in an isolated verification process.
- Three library regression tests passed, covering complete paged retrieval of all 127 skills, linked references, search, invalid requests, and path containment.
- Fourteen existing Swift tests passed. The release app build and strict code-signature verification passed.
- All 1,793 upstream and supplemental files matched their recorded hashes. All 70 existing project MCP entries and all 7 existing app MCP entries were preserved.

Run the library tests from the repository:

```sh
uv run --with mcp==1.26.0 --with PyYAML==6.0.3 python Tests/aws-skills/test_aws_skills.py
```

## Backup

`~/Library/Application Support/Forge/Backups/aws-toolkit-20260915/` contains the previous installed app, both original MCP files, and the prior MCP preferences. The project source changes remain uncommitted for review.
