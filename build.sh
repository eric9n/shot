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
# Sign with a fixed certificate if there is one, so macOS keeps the Screen Recording permission across rebuilds.
# An ad-hoc signature changes with every build, and macOS then treats each build as a new app and asks again.
# Create the certificate once in Keychain Access (see README), or set SHOT_SIGN_ID to another identity's name.
SIGN_ID="${SHOT_SIGN_ID:-Shot Local}"
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" $APP
    echo "Built $APP (signed with \"$SIGN_ID\")"
else
    codesign --force --sign - $APP
    echo "Built $APP (ad-hoc signed: macOS will ask for Screen Recording again after every rebuild;"
    echo "create a \"$SIGN_ID\" code-signing certificate to stop that, see README)"
fi
