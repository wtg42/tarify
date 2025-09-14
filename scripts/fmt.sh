#!/bin/sh
# Format Zig sources using the official formatter.
set -eu

echo "[fmt] zig fmt ."
zig fmt .

