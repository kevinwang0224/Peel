#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
if [[ "$(uname -m)" != "arm64" ]]; then echo "Peel Native currently targets Apple Silicon." >&2; exit 1; fi
bash "$native_root/scripts/prepare-dependencies.sh"
swift build --package-path "$native_root" -c "$configuration"
bin_dir="$(swift build --package-path "$native_root" -c "$configuration" --show-bin-path)"
app_path="$native_root/build/Peel Native.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/PeelNative" "$bin_dir/PeelScript" "$app_path/Contents/MacOS/"
cp "$native_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
ditto "$bin_dir/PeelNative_PeelScript.bundle" "$app_path/Contents/Resources/PeelNative_PeelScript.bundle"
for cursor in busy flipped; do
  sips -s format tiff "$native_root/Dependencies/scintilla/cocoa/res/mac_cursor_$cursor.png" --out "$app_path/Contents/Resources/mac_cursor_$cursor.tiff" >/dev/null
done
cp "$native_root/Dependencies/scintilla/License.txt" "$app_path/Contents/Resources/Scintilla-LICENSE.txt"
cp "$native_root/Dependencies/lexilla/License.txt" "$app_path/Contents/Resources/Lexilla-LICENSE.txt"
cp "$native_root/THIRD_PARTY_LICENSES/JSONPathPlus-LICENSE.txt" "$app_path/Contents/Resources/JSONPathPlus-LICENSE.txt"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PeelNative</string>
<key>CFBundleIdentifier</key><string>com.peel.native</string>
<key>CFBundleName</key><string>Peel Native</string>
<key>CFBundleDisplayName</key><string>Peel Native</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_path/Contents/MacOS/PeelScript"
codesign --force --sign - "$app_path"
printf 'Built: %s\n' "$app_path"
