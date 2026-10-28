#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$script_dir/.venv/bin/python" ]; then
    echo "Set up work-login/.venv first; see $script_dir/README.md" >&2
    exit 1
fi
exec "$script_dir/.venv/bin/python" "$script_dir/work_login.py" "$@"
