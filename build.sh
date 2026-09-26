#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Stage on the system volume: external volumes may create AppleDouble sidecars
# that cannot be processed by xattr/codesign.
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/ccs-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/ccs.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp ClaudeLogo.png CodexLogo.png "$app/Contents/Resources/"
swiftc -parse-as-library -O -framework AppKit -framework SwiftUI -framework Carbon -framework Security -framework ServiceManagement -lsqlite3 ccs.swift Accounts.swift Settings.swift -o "$app/Contents/MacOS/ccs"
xattr -cr "$app"
codesign --force --deep --sign - "$app"
ditto "$app" ccs.app
ditto -c -k --sequesterRsrc --keepParent "$app" ccs.zip
