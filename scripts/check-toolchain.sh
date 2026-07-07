#!/usr/bin/env bash
# Verify the Swift toolchain required by Forge.

set -euo pipefail

REQUIRED_MAJOR=6
REQUIRED_MINOR=2

if ! command -v swift >/dev/null 2>&1; then
  echo "error: Swift is not installed. Install Xcode or the Xcode command line tools." >&2
  exit 1
fi

raw="$(swift --version | head -n 1)"
version="$(printf '%s\n' "$raw" | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p')"

if [[ -z "$version" ]]; then
  echo "error: could not parse Swift version from: $raw" >&2
  exit 1
fi

major="${version%%.*}"
minor="${version#*.}"

if (( major < REQUIRED_MAJOR || (major == REQUIRED_MAJOR && minor < REQUIRED_MINOR) )); then
  echo "error: Forge requires Swift ${REQUIRED_MAJOR}.${REQUIRED_MINOR}+; found Swift ${version}." >&2
  echo "       Install Xcode 26+ or a newer Swift toolchain." >&2
  exit 1
fi

echo "Swift toolchain OK: $raw"
