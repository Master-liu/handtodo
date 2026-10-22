#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
FINAL_APP="$PWD/build/掌上待办.app"
VERSION="${HANDTODO_VERSION:-$(cat VERSION)}"
mkdir -p build/objects
APP_STAGE=$(mktemp -d "$PWD/build/app-stage.XXXXXX")
trap 'rm -rf "$APP_STAGE"' EXIT
APP="$APP_STAGE/掌上待办.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc Sources/*.swift -target arm64-apple-macosx13.0 -sdk "$SDK" -o "$APP/Contents/MacOS/HandTodo" -framework AppKit -O
cp Resources/hand.png Resources/hand-height.png "$APP/Contents/Resources/"
cp Resources/Brand/AppIcon-hi-v2/HandTodo.icns "$APP/Contents/Resources/HandTodo.icns"
mkdir -p "$APP/Contents/Resources/Doodles"
cp Resources/Doodles/*.png "$APP/Contents/Resources/Doodles/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HandTodo</string>
<key>CFBundleIdentifier</key><string>local.achoo.handtodo</string>
<key>CFBundleName</key><string>掌上待办</string>
<key>CFBundleIconFile</key><string>HandTodo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" "$VERSION" <<'PYVERSION'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as source: data=plistlib.load(source)
data['CFBundleShortVersionString']=sys.argv[2]
data['CFBundleVersion']=sys.argv[2]
with open(path,'wb') as output: plistlib.dump(data,output)
PYVERSION
codesign --force --sign - "$APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "$FINAL_APP"
