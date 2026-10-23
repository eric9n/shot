#!/bin/sh
# Builds Shot.app locally and ad-hoc signs it. Nothing is downloaded.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Shot.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/Shot $APP/Contents/MacOS/
mkdir -p $APP/Contents/Resources
rm -rf .build/AppIcon.iconset
swift icon/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Shot</string>
<key>CFBundleIdentifier</key><string>local.shot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Shot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - $APP
echo "Built $APP"
