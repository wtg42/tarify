#!/bin/sh
# Run all Zig tests in a portable way.
# POSIX-only; avoid bash-isms.
set -eu

echo "[test] zig build test"
zig build test

