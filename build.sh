#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/掌上待办.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc Sources/*.swift -o "$APP/Contents/MacOS/HandTodo" -framework AppKit -O
cp Resources/hand.png Resources/hand-height.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Doodles"
cp Resources/Doodles/*.png "$APP/Contents/Resources/Doodles/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HandTodo</string>
<key>CFBundleIdentifier</key><string>local.achoo.handtodo</string>
<key>CFBundleName</key><string>掌上待办</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
