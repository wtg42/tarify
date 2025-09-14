#!/bin/sh
# Minimal CI entry: format then test. Portable sh only.
set -eu

echo "[ci] formatting..."
zig fmt .

echo "[ci] running tests..."
zig build test

