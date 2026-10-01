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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp MiniInfo.plist "$app/Contents/Info.plist"
iconset="$build_dir/ccs.iconset"
mkdir -p "$iconset"
swift generate-icon.swift "$build_dir/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build_dir/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$build_dir/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ccs.icns"
swiftc -parse-as-library -O -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -lsqlite3 Mini.swift Accounts.swift -o "$app/Contents/MacOS/ccs-mini"
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
