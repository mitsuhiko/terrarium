#!/bin/bash
# Build ty's WebAssembly bindings (crates/ty_wasm) into app/vendor/ty_wasm.
# ty is not published to npm as wasm; the ty playground builds it the same way.
set -euo pipefail
cd "$(dirname "$0")/.."
RUFF_REV=350c634ad   # astral-sh/ruff main, 2026-10-13
OUT="$PWD/vendor/ty_wasm"
[ -f "$OUT/ty_wasm_bg.wasm" ] && [ "$(cat "$OUT/.rev" 2>/dev/null)" = "$RUFF_REV" ] && exit 0

CHECKOUT="$HOME/.cache/checkouts/github.com/astral-sh/ruff"
[ -d "$CHECKOUT" ] || git clone --filter=blob:none https://github.com/astral-sh/ruff "$CHECKOUT"
git -C "$CHECKOUT" cat-file -e "$RUFF_REV^{commit}" 2>/dev/null || git -C "$CHECKOUT" fetch origin
WORK="$HOME/.cache/terrarium-ruff-$RUFF_REV"
[ -d "$WORK" ] || git -C "$CHECKOUT" worktree add --detach "$WORK" "$RUFF_REV"

rustup target add wasm32-unknown-unknown >/dev/null
CARGO_TARGET_DIR="$HOME/.cache/terrarium-cargo-target" \
  wasm-pack build "$WORK/crates/ty_wasm" --target web --release --out-dir "$OUT"
echo "$RUFF_REV" > "$OUT/.rev"
