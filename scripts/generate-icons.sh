#!/usr/bin/env bash
# Regenerates Resources/Icons/AppIcon.icns and AppIconLight.icns from the SVG sources.
# The SVGs are rasterised with Quick Look (it matches Monaco's glyph metrics), then clipped to the
# icon squircle so the outer corners are transparent.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/Resources/Icons/Source"
output_dir="$root/Resources/Icons"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

qlmanage -t -s 1024 -o "$work" "$source_dir/AppIcon.svg" "$source_dir/AppIconLight.svg" >/dev/null 2>&1

swift - "$work" <<'SWIFT'
import AppKit

let work = CommandLine.arguments[1]
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// One point inside the SVG squircle (100, 100, 824, 824, r173) to drop Quick Look's white edge fringe.
let clip = CGPath(
  roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822), cornerWidth: 172, cornerHeight: 172,
  transform: nil)
let sizes: [(String, Int)] = [
  ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
  ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
  ("512x512@2x", 1024),
]

func bitmapContext(_ pixels: Int) -> CGContext {
  CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to path: String) {
  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
  try! data.write(to: URL(fileURLWithPath: path))
}

for name in ["AppIcon", "AppIconLight"] {
  let source = NSImage(contentsOfFile: "\(work)/\(name).svg.png")!
  var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
  let image = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
  let master = bitmapContext(1024)
  master.addPath(clip)
  master.clip()
  master.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
  let masterImage = master.makeImage()!

  let iconset = "\(work)/\(name).iconset"
  try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
  for (label, pixels) in sizes {
    let context = bitmapContext(pixels)
    context.interpolationQuality = .high
    context.draw(masterImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    writePNG(context.makeImage()!, to: "\(iconset)/icon_\(label).png")
  }
}
SWIFT

for name in AppIcon AppIconLight; do
  iconutil -c icns "$work/$name.iconset" -o "$output_dir/$name.icns"
done
echo "Updated $output_dir/AppIcon.icns and AppIconLight.icns"
