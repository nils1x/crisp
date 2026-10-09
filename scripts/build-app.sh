#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
swift test -j 2
swift build -c release -j 2

app="$root/build/Crisp.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/Crisp" "$app/Contents/MacOS/Crisp"
cp "$root/SPACE-RABBIT-LICENSE.md" "$root/FASTER-SWIPER-LICENSE" "$app/Contents/Resources/"
cp "$root/Resources/MenuBarSupra.png" "$root/Resources/MenuBarSupra@2x.png" "$app/Contents/Resources/"
iconutil -c icns "$root/Resources/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.nils.crisp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Crisp</string>
  <key>CFBundleName</key><string>Crisp</string>
  <key>CFBundleDisplayName</key><string>Crisp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/{print $2; exit}')
if [[ -z "$identity" ]]; then
  print -u2 "No Apple Development signing identity found; refusing to produce an unstable unsigned bundle."
  exit 1
fi
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"
plutil -lint "$app/Contents/Info.plist"
print "Built $app"
