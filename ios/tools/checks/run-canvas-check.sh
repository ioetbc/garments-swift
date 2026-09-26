#!/bin/zsh
set -e
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -module-cache-path /tmp/garms-swift-modules -sdk "$sdk" -target arm64-apple-ios26.2-macabi -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" -L "$sdk/System/iOSSupport/usr/lib" ios/SharedImports/*.swift ios/Garms/Imports/*.swift ios/Garms/App/GarmsAPI.swift ios/Garms/Canvas/Canvas{Session,Document,Geometry,SpatialIndex,Fixtures,AssetStore,InteractionController}.swift "$1" -o /tmp/garms-canvas-checks
/tmp/garms-canvas-checks
