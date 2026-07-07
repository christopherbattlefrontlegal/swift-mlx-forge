#!/usr/bin/env bash
# Build Forge.app, install it into /Applications, then launch it.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OPEN_AFTER=1

for arg in "$@"; do
  case "$arg" in
    --no-open)
      OPEN_AFTER=0
      ;;
    -h|--help)
      echo "Usage: ./scripts/install-forge-app.sh [--no-open]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./scripts/install-forge-app.sh [--no-open]" >&2
      exit 2
      ;;
  esac
done

"$REPO/scripts/build-app.sh" /Applications

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  open /Applications/Forge.app
fi
