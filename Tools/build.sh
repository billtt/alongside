#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
stage=$(mktemp -d "${TMPDIR:-/tmp}/alongside-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Alongside.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -module-cache-path "$stage/cache" -target "$arch-apple-macosx13.0" Sources/*.swift -o "$stage/$arch"
done
lipo -create "$stage/arm64" "$stage/x86_64" -output "$bundle/Contents/MacOS/Alongside"
cp Resources/Info.plist "$bundle/Contents/"
cp -R Resources/Pets "$bundle/Contents/Resources/"
cp Resources/Alongside.icns "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
ditto "$bundle" dist/Alongside.app
