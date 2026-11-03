#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin="$script_dir/.build/camera-screenshot"
src="$script_dir/camera_screenshot.swift"
# Compile once (optimised) and reuse; recompile only when the source changes.
if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    mkdir -p "$script_dir/.build"
    swiftc -O -o "$bin" "$src"
fi
exec "$bin" "$@"
