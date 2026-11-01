#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$script_dir/.venv/bin/python" ] || [ ! -d "$script_dir/model" ]; then
    echo "Run $script_dir/setup.sh first (one-time, needs Internet)" >&2
    exit 1
fi
exec "$script_dir/.venv/bin/python" "$script_dir/speak_digits.py" "$@"
