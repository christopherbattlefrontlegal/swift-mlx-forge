#!/usr/bin/env bash
# Forge — repeatable security regression check.
#
# Runs static regression checks for either the local developer build or the
# Mac App Store sandbox profile:
#
#     ./scripts/security-check.sh --developer
#     ./scripts/security-check.sh --mas
#
# Exit code 0 = clean, 1 = something regressed (details printed). Static-only —
# it greps source for the footguns we already fixed so they can't sneak back.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
SRC="Sources"
fail=0
MODE="${1:---developer}"

case "$MODE" in
  --developer|--mas) ;;
  *)
    echo "Usage: ./scripts/security-check.sh [--developer|--mas]"
    exit 2
    ;;
esac

red()  { printf '\033[31m✗ %s\033[0m\n' "$1"; }
grn()  { printf '\033[32m✓ %s\033[0m\n' "$1"; }
note() { printf '  → %s\n' "$1"; }

check_absent() { # <description> <grep-args...>
  local desc="$1"; shift
  local hits
  hits="$(grep -rnE "$@" "$SRC" --include='*.swift' 2>/dev/null)"
  if [[ -n "$hits" ]]; then
    red "$desc"; echo "$hits" | sed 's/^/     /'; fail=1
  else
    grn "$desc"
  fi
}

echo "── Forge security check ($MODE) ─────────────────────"

# 1. Process spawning is required for developer stdio MCP support, but it is
#    still forbidden in the Mac App Store sandbox profile.
proc_hits="$(grep -rnE 'Process\(\)|process\.run\(|posix_spawn|/bin/sh' \
  "$SRC/mlx-forge" --include='*.swift' 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//')"
if [[ -n "$proc_hits" && "$MODE" == "--mas" ]]; then
  red "Process spawning in Forge is incompatible with MAS sandbox signing"
  echo "$proc_hits" | sed 's/^/     /'; fail=1
elif [[ -n "$proc_hits" ]]; then
  grn "Process spawning allowed for developer stdio MCP build"
else
  grn "No process spawning in Forge"
fi

# 2. The local server must never serve a wildcard CORS origin.
check_absent "No wildcard CORS (Access-Control-Allow-Origin: *)" \
  'Allow-Origin: \*'

# 3. No plaintext HTTP endpoints except the loopback server's own base URL.
check_absent "No non-loopback http:// URLs" \
  'http://(?!127\.0\.0\.1|localhost)'

# 4. TLS must never be disabled.
check_absent "No disabled TLS / arbitrary loads" \
  'NSAllowsArbitraryLoads|allowsAnyHTTPSCertificate|\.serverTrust'

# 5. No hardcoded secrets (placeholders like hf_xxx / sk-ant-… are allowed).
secrets="$(grep -rnE 'hf_[A-Za-z0-9]{20,}|sk-(ant-)?[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}' \
  "$SRC" --include='*.swift' 2>/dev/null | grep -vE 'x{8,}|…|placeholder')"
if [[ -n "$secrets" ]]; then
  red "Possible hardcoded secret"; echo "$secrets" | sed 's/^/     /'; fail=1
else
  grn "No hardcoded secrets"
fi

# 6. Server must keep enforcing a Host allowlist (the DNS-rebinding guard).
if grep -rqE 'localIdentity|hosts\.contains' "$SRC/mlx-forge/ForgeServer.swift" 2>/dev/null; then
  grn "Server Host-header allowlist present"
else
  red "Server Host-header allowlist MISSING — DNS-rebinding guard gone"; fail=1
fi

echo "──────────────────────────────────────────────────────"
if [[ "$fail" -eq 0 ]]; then
  if [[ "$MODE" == "--mas" ]]; then
    grn "CLEAN — safe for MAS sandbox signing checks"
  else
    grn "CLEAN — developer build checks passed"
  fi
else
  red "REGRESSION FOUND — fix before shipping"
  note "Use --mas for App Store sandbox constraints and --developer for local stdio MCP builds."
fi
exit "$fail"
