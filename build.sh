#!/bin/bash
# Build "Model Cache Manager.app". Pass --install to copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Model Cache Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ModelCacheManager "$APP/Contents/MacOS/ModelCacheManager"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Assets/logo.png "$APP/Contents/Resources/logo.png"
cp LICENSE NOTICE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Model Cache Manager</string>
  <key>CFBundleDisplayName</key><string>Model Cache Manager</string>
  <key>CFBundleIdentifier</key><string>io.github.fredriklindstrom.modelcachemanager</string>
  <key>CFBundleExecutable</key><string>ModelCacheManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Fredrik Lindstrom. Apache License 2.0.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Model Cache Manager.app"
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/Model Cache Manager.app"
fi
