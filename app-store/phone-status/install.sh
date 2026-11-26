#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Phone Status.app"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Phone Status.app"
mkdir -p "$bundle/Contents/"{MacOS,Resources} "$HOME/Applications"
xcrun swiftc -O -parse-as-library PhoneStatus.swift -o "$bundle/Contents/MacOS/PhoneStatus"
cp ../phone_status.py "$bundle/Contents/Resources/"
cp Info.plist "$bundle/Contents/"
codesign --force --sign - "$bundle"
if pgrep -fx "$app/Contents/MacOS/PhoneStatus" >/dev/null; then
    osascript -e 'tell application id "dev.mac-tooling.PhoneStatus" to quit'
fi
ditto "$bundle" "$app"
open "$app"
