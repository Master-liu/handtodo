#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TARGET="$PWD/Distribution/output/HandTodo-0.2.0-Windows-x64"
mkdir -p "$TARGET"
dotnet publish Windows/HandTodo.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows-x64
cp build/windows-x64/HandTodo.exe "$TARGET/"
cp Distribution/使用说明-Windows.txt "$TARGET/使用说明.txt"
python3 - <<'ZIP'
from pathlib import Path
import zipfile
folder=Path('Distribution/output/HandTodo-0.2.0-Windows-x64')
with zipfile.ZipFile(folder.with_suffix('.zip'),'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for name in ['HandTodo.exe','使用说明.txt']:
        archive.write(folder/name,arcname=folder.name+'/'+name)
ZIP
