#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./build.sh
mkdir -p Distribution/output build/macos-package
STAGE="$PWD/build/macos-package"
ditto "build/掌上待办.app" "$STAGE/掌上待办.app"
ln -sfn /Applications "$STAGE/Applications"
cp Distribution/使用说明-Mac.txt "$STAGE/使用说明.txt"
hdiutil create -volname '掌上待办' -srcfolder "$STAGE" -ov -format UDZO Distribution/output/HandTodo-0.2.0-macOS-Universal.dmg
hdiutil verify Distribution/output/HandTodo-0.2.0-macOS-Universal.dmg
