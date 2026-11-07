#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/amber-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/amber-swift-cache"
swift build -c release --disable-sandbox -debug-info-format none
binary_dir="$(swift build -c release --show-bin-path --disable-sandbox)"
app="build/Amber.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/AmberNotepad" "$app/Contents/MacOS/AmberNotepad"
cp Assets/Amber.icns "$app/Contents/Resources/Amber.icns"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
