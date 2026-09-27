#!/bin/sh
set -eu
cd "$(dirname "$0")"
output_dir=${CCS_OUTPUT_DIR:-$PWD}
mkdir -p "$output_dir"
if [ "$output_dir" = "$PWD" ] && /bin/ps -axo comm= | /usr/bin/grep -Fxq "$PWD/ccs-mini.app/Contents/MacOS/ccs-mini"; then
    echo "Quit ccs mini before building." >&2
    exit 1
fi
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/ccs-mini-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/ccs-mini.app"
mkdir -p "$app/Contents/MacOS"
cp MiniInfo.plist "$app/Contents/Info.plist"
swiftc -parse-as-library -O -framework AppKit -framework SwiftUI -framework Security Mini.swift Accounts.swift -o "$app/Contents/MacOS/ccs-mini"
xattr -cr "$app"
if [ -n "${CCS_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CCS_CODESIGN_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --strict --verbose=2 "$app"
rm -rf "$output_dir/ccs-mini.app"
ditto "$app" "$output_dir/ccs-mini.app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/ccs-mini.zip"
