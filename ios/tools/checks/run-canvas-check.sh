#!/bin/zsh
set -e
sdk=$(xcrun --sdk macosx --show-sdk-path)
# PencilKit requires a bundle identifier when it creates stroke replicas.
check_bundle=$(mktemp -d /tmp/garms-canvas-check.XXXXXX)
trap 'rm -rf "$check_bundle"' EXIT
mkdir -p "$check_bundle/Checks.app/Contents/MacOS"
cat > "$check_bundle/Checks.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.garms.canvas-checks</string>
<key>CFBundleExecutable</key><string>checks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -module-cache-path /tmp/garms-swift-modules -sdk "$sdk" -target arm64-apple-ios26.2-macabi -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" -L "$sdk/System/iOSSupport/usr/lib" ios/SharedImports/*.swift ios/Garms/Imports/*.swift ios/Garms/App/GarmsAPI.swift ios/Garms/Canvas/Canvas{History,Session,Document,Geometry,SpatialIndex,Fixtures,AssetStore,InteractionController,InkView}.swift "$1" -o "$check_bundle/Checks.app/Contents/MacOS/checks"
"$check_bundle/Checks.app/Contents/MacOS/checks"
