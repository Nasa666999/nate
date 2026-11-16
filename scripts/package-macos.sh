#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
swift scripts/RenderIcon.swift assets/icons
iconutil -c icns assets/icons/Nate.iconset -o assets/icons/Nate.icns
swift scripts/ResourceManifest.swift resources
app_dir="$project_dir/dist/Nate.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/nate "$app_dir/Contents/MacOS/nate"
cp packaging/macos/Info.plist "$app_dir/Contents/Info.plist"
cp -R resources/. "$app_dir/Contents/Resources/"
cp assets/icons/Nate.icns "$app_dir/Contents/Resources/Nate.icns"
cp LICENSE "$app_dir/Contents/Resources/licenses/Nate-GPL.txt"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'App: %s\n' "$app_dir"
