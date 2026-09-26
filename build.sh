#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p SessionSpot.app/Contents/MacOS SessionSpot.app/Contents/Resources
cp Info.plist SessionSpot.app/Contents/Info.plist
cp ClaudeLogo.png CodexLogo.png SessionSpot.app/Contents/Resources/
rm -f SessionSpot.app/Contents/Resources/ProviderLogos.png
swiftc -parse-as-library -O -framework AppKit -framework SwiftUI -framework Carbon -lsqlite3 SessionSpot.swift -o SessionSpot.app/Contents/MacOS/SessionSpot
xattr -cr SessionSpot.app
codesign --force --deep --sign - SessionSpot.app
ditto -c -k --sequesterRsrc --keepParent SessionSpot.app SessionSpot.zip
