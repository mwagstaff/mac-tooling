#!/bin/sh
# One-time setup: creates the venv and downloads the offline speech model.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"
model=vosk-model-small-en-us-0.15

python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt

if [ ! -d model ]; then
    curl -fSLO "https://alphacephei.com/vosk/models/$model.zip"
    unzip -q "$model.zip"
    mv "$model" model
    rm "$model.zip"
fi
echo "Ready: $script_dir/speak-digits.sh"
