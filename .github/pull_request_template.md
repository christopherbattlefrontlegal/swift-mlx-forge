## What changed

Describe the user-visible result and the reason for the change.

## Verification

- [ ] `swift test`
- [ ] `swift build --product mlx-forge`
- [ ] `./scripts/security-check.sh --developer`
- [ ] I verified affected interface changes in the running app.
- [ ] I verified the Forge Graph production build when graph code changed.

List any checks that do not apply and explain why.

## Safety and scope

- [ ] No model weights, credentials, private prompts, local paths, or generated caches are included.
- [ ] The local API remains loopback-only and does not use wildcard CORS.
- [ ] Sandboxed App Store code does not spawn external commands.
- [ ] The change is limited to the described scope.

## Screenshots

Include before-and-after images for visible interface changes.
