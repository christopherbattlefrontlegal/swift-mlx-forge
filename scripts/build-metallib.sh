#!/bin/bash
# Build mlx.metallib for the Swift-native MLX runtime.
#
# Why this exists:
#   mlx-swift (0.31.x) builds its Metal GPU backend in JIT mode when compiled
#   with plain SwiftPM (`swift build`). At runtime MLX still needs a base
#   `mlx.metallib` containing the precompiled "always-AOT" kernels. The Xcode
#   build produces this automatically; a pure `swift build` does not. This
#   script reproduces the upstream metallib build (see
#   Source/Cmlx/mlx/mlx/backend/metal/kernels/CMakeLists.txt) and colocates the
#   resulting `mlx.metallib` next to the runtime executable, which is the first
#   location MLX searches (load_colocated_library(device, "mlx")).
#
# Usage:
#   scripts/build-metallib.sh [release|debug]
#
set -euo pipefail

CONFIG="${1:-release}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_ROOT="$PKG_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS_DIR="$MLX_ROOT/mlx/backend/metal/kernels"
BIN_DIR="$PKG_DIR/.build/$CONFIG"

if [ ! -d "$KERNELS_DIR" ]; then
    echo "error: kernel sources not found at $KERNELS_DIR" >&2
    echo "       run 'swift build -c $CONFIG' first so dependencies are checked out." >&2
    exit 1
fi
if [ ! -d "$BIN_DIR" ]; then
    echo "error: build dir not found at $BIN_DIR -- run 'swift build -c $CONFIG' first." >&2
    exit 1
fi

# Deployment target must match the package (macOS 14).
MIN_OS="14.0"

# Base (non-JIT) kernels — these mirror the always-built list in CMakeLists.txt
# (the block above `if(NOT MLX_METAL_JIT)`), which are required even in JIT mode.
KERNELS=(
    arg_reduce
    conv
    gemv
    layer_norm
    random
    rms_norm
    rope
    scaled_dot_product_attention
    fence
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Determine the highest Metal language standard the installed toolchain supports.
# fence.metal uses Metal 3.2 features (coherent(system)); fall back gracefully.
METAL_STD="-std=metal3.2"
if ! echo 'kernel void k() {}' | xcrun -sdk macosx metal -x metal "$METAL_STD" -c - -o /dev/null 2>/dev/null; then
    METAL_STD="-std=metal3.1"
fi

METAL_FLAGS=(-x metal "$METAL_STD" -Wall -Wextra -fno-fast-math
    -Wno-c++17-extensions -Wno-c++20-extensions
    "-mmacosx-version-min=$MIN_OS")

AIR_FILES=()
echo "Compiling Metal kernels (config: $CONFIG)..."
for k in "${KERNELS[@]}"; do
    src="$KERNELS_DIR/$k.metal"
    if [ ! -f "$src" ]; then
        echo "  skip $k (no source)"
        continue
    fi
    out="$WORK/$(basename "$k").air"
    echo "  metal -c $k.metal"
    xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$src" -I "$MLX_ROOT" -o "$out"
    AIR_FILES+=("$out")
done

if [ "${#AIR_FILES[@]}" -eq 0 ]; then
    echo "error: no kernels compiled" >&2
    exit 1
fi

echo "Linking mlx.metallib -> $BIN_DIR/mlx.metallib"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$BIN_DIR/mlx.metallib"

echo "Done. mlx.metallib placed next to the executable."
ls -lh "$BIN_DIR/mlx.metallib"
