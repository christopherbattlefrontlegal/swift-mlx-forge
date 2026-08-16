#!/usr/bin/env bash
# Build the vendored Ironclad Rivet browser frontend used by Forge.

set -euo pipefail
cd "$(dirname "$0")/../BundledTools/rivet"

YARN=".yarn/releases/yarn-4.6.0.cjs"
[[ -f "$YARN" ]] || { echo "Missing vendored Yarn: $YARN" >&2; exit 1; }

node "$YARN" install --immutable
node "$YARN" workspace @ironclad/rivet-core build
node "$YARN" workspace @ironclad/trivet build
node "$YARN" workspace @ironclad/rivet-app build

[[ -f packages/app/dist/index.html ]] || {
  echo "Rivet build did not produce packages/app/dist/index.html" >&2
  exit 1
}

rm -rf dist
mkdir -p dist
cp -R packages/app/dist/. dist/
