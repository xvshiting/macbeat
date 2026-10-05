#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="${MACBEAT_APP_OUTPUT:-$PWD/dist/MacBeat.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/MacBeat" "$app/Contents/MacOS/MacBeat"
cp "$bin/MacBeatAgent" "$app/Contents/Helpers/MacBeatAgent"
swift scripts/make-icon.swift .build/MacBeat.iconset
iconutil -c icns .build/MacBeat.iconset -o "$app/Contents/Resources/MacBeat.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier dev.macbeat.agent "$app/Contents/Helpers/MacBeatAgent"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
