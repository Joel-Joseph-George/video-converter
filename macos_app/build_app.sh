#!/usr/bin/env zsh
# Build the native macOS drag-and-drop application bundle: "Video Converter.app".
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(cd -- "${APP_DIR}/.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/Video Converter.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Compiling MKVToMP4App.swift..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -o "${MACOS_DIR}/MKVToMP4" \
  "${APP_DIR}/MKVToMP4App.swift"

echo "Generating app icon..."
cat > "${TMP_DIR}/make_icon.swift" <<'SWIFT'
import AppKit
import Foundation

let iconsetPath = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, filename) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = CGFloat(px) * 0.06
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(px) * 0.22
    let path = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.28, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.78, alpha: 1.0)
    )!
    gradient.draw(in: path, angle: -45)

    NSColor.white.withAlphaComponent(0.22).setStroke()
    path.lineWidth = max(1.0, CGFloat(px) * 0.015)
    path.stroke()

    let titleFont = NSFont.systemFont(ofSize: CGFloat(px) * 0.21, weight: .heavy)
    let arrowFont = NSFont.systemFont(ofSize: CGFloat(px) * 0.17, weight: .bold)
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    let mkvStr = NSAttributedString(
        string: "MKV",
        attributes: [.font: titleFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: para]
    )
    let arrowStr = NSAttributedString(
        string: "↓",
        attributes: [.font: arrowFont, .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.70, alpha: 1.0), .paragraphStyle: para]
    )
    let mp4Str = NSAttributedString(
        string: "MP4",
        attributes: [.font: titleFont, .foregroundColor: NSColor.white, .paragraphStyle: para]
    )

    mkvStr.draw(in: NSRect(x: 0, y: CGFloat(px) * 0.57, width: CGFloat(px), height: CGFloat(px) * 0.28))
    arrowStr.draw(in: NSRect(x: 0, y: CGFloat(px) * 0.39, width: CGFloat(px), height: CGFloat(px) * 0.22))
    mp4Str.draw(in: NSRect(x: 0, y: CGFloat(px) * 0.15, width: CGFloat(px), height: CGFloat(px) * 0.28))

    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename))
}
SWIFT

ICONSET_DIR="${TMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
swift "${TMP_DIR}/make_icon.swift" "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

echo "Copying helper scripts into app bundle..."
cp "${ROOT_DIR}/mkv_to_mp4.py" "${RESOURCES_DIR}/mkv_to_mp4.py"
cp "${ROOT_DIR}/setup_ffmpeg.sh" "${RESOURCES_DIR}/setup_ffmpeg.sh"
chmod +x "${RESOURCES_DIR}/mkv_to_mp4.py" "${RESOURCES_DIR}/setup_ffmpeg.sh"

if [[ -x "${ROOT_DIR}/bin/ffmpeg" && -x "${ROOT_DIR}/bin/ffprobe" ]]; then
  mkdir -p "${RESOURCES_DIR}/bin"
  cp "${ROOT_DIR}/bin/ffmpeg" "${RESOURCES_DIR}/bin/ffmpeg"
  cp "${ROOT_DIR}/bin/ffprobe" "${RESOURCES_DIR}/bin/ffprobe"
  chmod +x "${RESOURCES_DIR}/bin/ffmpeg" "${RESOURCES_DIR}/bin/ffprobe"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MKVToMP4</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.videoconverter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Video Converter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mkv</string>
                <string>MKV</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Matroska Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
        <dict>
            <key>CFBundleTypeOSTypes</key>
            <array>
                <string>fold</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${BUNDLE_DIR}" >/dev/null 2>&1 || true

echo "Built successfully: ${BUNDLE_DIR}"

