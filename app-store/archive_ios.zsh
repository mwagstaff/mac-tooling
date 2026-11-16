#!/usr/bin/env zsh
set -euo pipefail
exec python3 "${0:A:h}/archive_ios.py" "$@"
