#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_root="$project_root/Sources/PeelEditor/Vendor"
configuration="${1:-release}"
if [[ "$(uname -m)" != "arm64" ]]; then echo "Peel currently targets Apple Silicon." >&2; exit 1; fi
bash "$project_root/scripts/prepare-dependencies.sh"
# Keep the deployment target at macOS 14 but record the current SDK in LC_BUILD_VERSION,
# otherwise macOS treats the binary as built with an old SDK and skips the Liquid Glass design.
sdk_version="$(xcrun --show-sdk-version)"
link_flags=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version")
swift build --package-path "$project_root" -c "$configuration" "${link_flags[@]}"
bin_dir="$(swift build --package-path "$project_root" -c "$configuration" --show-bin-path)"
app_path="$project_root/build/Peel.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/Peel" "$bin_dir/PeelScript" "$app_path/Contents/MacOS/"
cp "$project_root/Resources/Icons/AppIcon.icns" "$project_root/Resources/Icons/AppIconLight.icns" "$app_path/Contents/Resources/"
ditto "$bin_dir/Peel_PeelScript.bundle" "$app_path/Contents/Resources/Peel_PeelScript.bundle"
for cursor in busy flipped; do
  sips -s format tiff "$vendor_root/scintilla/cocoa/res/mac_cursor_$cursor.png" --out "$app_path/Contents/Resources/mac_cursor_$cursor.tiff" >/dev/null
done
cp "$vendor_root/scintilla/License.txt" "$app_path/Contents/Resources/Scintilla-LICENSE.txt"
cp "$vendor_root/lexilla/License.txt" "$app_path/Contents/Resources/Lexilla-LICENSE.txt"
cp "$project_root/Resources/Licenses/JSONPathPlus-LICENSE.txt" "$app_path/Contents/Resources/JSONPathPlus-LICENSE.txt"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Peel</string>
<key>CFBundleIdentifier</key><string>com.peel.native</string>
<key>CFBundleName</key><string>Peel</string>
<key>CFBundleDisplayName</key><string>Peel</string>
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
