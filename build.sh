#!/bin/sh
set -eu
cd "$(dirname "$0")"
ensure_app_stopped() {
    if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$PWD/ccs.app/Contents/MacOS/ccs"; then
        echo "Quit ccs before building. Replacing a running app breaks its code signature and Keychain access." >&2
        exit 1
    fi
}
ensure_app_stopped
# Stage on the system volume: external volumes may create AppleDouble sidecars
# that cannot be processed by xattr/codesign.
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/ccs-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/ccs.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
iconset="$build_dir/ccs.iconset"
mkdir -p "$iconset"
swift generate-icon.swift "$build_dir/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build_dir/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$build_dir/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ccs.icns"
swiftc -parse-as-library -O -framework AppKit -framework SwiftUI -framework Carbon -framework Security -framework ServiceManagement -lsqlite3 ccs.swift Accounts.swift Settings.swift -o "$app/Contents/MacOS/ccs"
xattr -cr "$app"
codesign --force --deep --sign - "$app"
ensure_app_stopped
rm -rf ccs.app
ditto "$app" ccs.app
ditto -c -k --sequesterRsrc --keepParent "$app" ccs.zip
