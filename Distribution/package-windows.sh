#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TARGET="$PWD/Distribution/output/HandTodo-0.2.0-Windows-x64"
mkdir -p "$TARGET"
dotnet publish Windows/HandTodo.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows-x64
cp build/windows-x64/HandTodo.exe "$TARGET/"
cp Distribution/使用说明-Windows.txt "$TARGET/使用说明.txt"
ditto -c -k --keepParent "$TARGET" Distribution/output/HandTodo-0.2.0-Windows-x64.zip
