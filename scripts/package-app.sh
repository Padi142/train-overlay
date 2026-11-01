#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TrainAlarm"
APP_BUNDLE=".build/${APP_NAME}.app"
BUILD_CONFIG="release"
BUILD_BIN=".build/${BUILD_CONFIG}/${APP_NAME}"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"
APP_PLIST="${APP_CONTENTS}/Info.plist"
ICON_WORK_DIR=".build/icon-work"
ICON_SWIFT="${ICON_WORK_DIR}/generate_icon.swift"
BASE_ICON="${ICON_WORK_DIR}/base_icon.png"
ICONSET_DIR="${ICON_WORK_DIR}/${APP_NAME}.iconset"
APP_ICNS="${APP_RESOURCES}/${APP_NAME}.icns"
INSTALL_DIR="/Applications"

echo "Building ${APP_NAME} (${BUILD_CONFIG})..."
swift build -c "${BUILD_CONFIG}"

if [[ ! -f "${BUILD_BIN}" ]]; then
  echo "Error: build output not found at ${BUILD_BIN}" >&2
  exit 1
fi

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_MACOS}" "${APP_RESOURCES}"
cp "${BUILD_BIN}" "${APP_MACOS}/${APP_NAME}"

echo "Generating train app icon..."
rm -rf "${ICON_WORK_DIR}"
mkdir -p "${ICON_WORK_DIR}" "${ICONSET_DIR}"

cat > "${ICON_SWIFT}" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Missing output path\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let canvasRect = NSRect(x: 0, y: 0, width: size, height: size)
let badgeRect = canvasRect.insetBy(dx: 32, dy: 32)
let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 210, yRadius: 210)

let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.33, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.63, alpha: 1)
])!
background.draw(in: badgePath, angle: -35)

NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
badgePath.lineWidth = 14
badgePath.stroke()

let bodyRect = NSRect(x: 190, y: 300, width: 644, height: 360)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 120, yRadius: 120)
NSColor(calibratedWhite: 0.97, alpha: 1.0).setFill()
bodyPath.fill()

let windshieldRect = NSRect(x: 260, y: 440, width: 504, height: 150)
let windshieldPath = NSBezierPath(roundedRect: windshieldRect, xRadius: 72, yRadius: 72)
NSColor(calibratedRed: 0.11, green: 0.28, blue: 0.53, alpha: 1).setFill()
windshieldPath.fill()

for index in 0..<3 {
    let x = 302 + CGFloat(index) * 150
    let window = NSBezierPath(roundedRect: NSRect(x: x, y: 465, width: 105, height: 90), xRadius: 28, yRadius: 28)
    NSColor(calibratedRed: 0.39, green: 0.70, blue: 0.98, alpha: 1).setFill()
    window.fill()
}

let stripe = NSBezierPath(roundedRect: NSRect(x: 250, y: 375, width: 524, height: 48), xRadius: 24, yRadius: 24)
NSColor(calibratedRed: 0.98, green: 0.63, blue: 0.22, alpha: 1).setFill()
stripe.fill()

let wheelY: CGFloat = 268
for x in [320.0, 512.0, 704.0] {
    let outerWheel = NSBezierPath(ovalIn: NSRect(x: x - 46, y: wheelY - 46, width: 92, height: 92))
    NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
    outerWheel.fill()

    let innerWheel = NSBezierPath(ovalIn: NSRect(x: x - 24, y: wheelY - 24, width: 48, height: 48))
    NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
    innerWheel.fill()
}

let rail = NSBezierPath()
rail.move(to: NSPoint(x: 220, y: 225))
rail.line(to: NSPoint(x: 804, y: 225))
rail.lineWidth = 24
rail.lineCapStyle = .round
NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
rail.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Failed to render PNG icon\n", stderr)
    exit(2)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Failed to write PNG icon: \(error)\n", stderr)
    exit(3)
}
SWIFT

swift "${ICON_SWIFT}" "${BASE_ICON}"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "${size}" "${size}" "${BASE_ICON}" --out "${ICONSET_DIR}/${name}" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${APP_ICNS}"

cat > "${APP_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TrainAlarm</string>
  <key>CFBundleDisplayName</key><string>TrainAlarm</string>
  <key>CFBundleIdentifier</key><string>cz.trainalarm.app</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleExecutable</key><string>TrainAlarm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>TrainAlarm</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "Signing app bundle (ad-hoc)..."
codesign --force --deep --sign - "${APP_BUNDLE}"

INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}.app"
echo "Installing to ${INSTALLED_APP}..."
pkill -x "${APP_NAME}" 2>/dev/null || true
if rm -rf "${INSTALLED_APP}" 2>/dev/null && cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/" 2>/dev/null; then
  echo "Installed: ${INSTALLED_APP}"
else
  echo "No permission to write ${INSTALL_DIR}. Re-run with sudo:" >&2
  echo "  sudo cp -R \"${APP_BUNDLE}\" \"${INSTALL_DIR}/\"" >&2
  exit 2
fi

echo "Opening app..."
open "${INSTALLED_APP}"

echo "Done."
