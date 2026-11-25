#!/usr/bin/env bash
# Select the Xcode toolchain for every later step.
#
# The `xcode` workflow input pins /Applications/Xcode_<version>.app; empty selects the newest installed Xcode.
# DEVELOPER_DIR is what UniXNU's own macos.yml sets, and what the UniXNU build scripts expect (xcrun --sdk macosx).
set -euo pipefail

echo "== installed Xcodes"
for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    printf '%-44s %s\n' "$app" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
done

requested="${XCODE_VERSION:-}"
if [ -n "$requested" ]; then
    app="/Applications/Xcode_${requested}.app"
else
    app="$(ls -d /Applications/Xcode*.app | sort -V | tail -n 1)"
fi
if [ ! -d "$app/Contents/Developer" ]; then
    echo "::error::no full Xcode at $app"
    exit 1
fi

echo "DEVELOPER_DIR=$app/Contents/Developer" >> "$GITHUB_ENV"
echo "XCODE_APP=$app" >> "$GITHUB_ENV"
echo "== selected $app"
DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version
path="$(DEVELOPER_DIR="$app/Contents/Developer" xcrun --sdk macosx --show-sdk-path)"
version="$(DEVELOPER_DIR="$app/Contents/Developer" xcrun --sdk macosx --show-sdk-version)"
build="$(DEVELOPER_DIR="$app/Contents/Developer" xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || echo unknown)"
echo "macOS SDK $version ($build) at $path"
echo "SDK_PATH=$path" >> "$GITHUB_ENV"
echo "SDK_VERSION=$version ($build)" >> "$GITHUB_ENV"
