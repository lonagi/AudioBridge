#!/usr/bin/env bash
# Builds AudioBridge.app (Mac receiver) with the Windows sender package inside.
#
#   scripts/build.sh            build into ./build
#   scripts/build.sh --install  build, then replace /Applications/AudioBridge.app and relaunch it
#
# Pairing config: $CONFIG, else ./connection.json, else the one inside the installed app,
# so a rebuild keeps the existing Mac and Windows pair. Create a new pair with scripts/new-pairing.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build"
INSTALLED=/Applications/AudioBridge.app

if [ -z "${CONFIG:-}" ]; then
  if [ -f "$ROOT/connection.json" ]; then CONFIG="$ROOT/connection.json"
  elif [ -f "$INSTALLED/Contents/Resources/connection.json" ]; then CONFIG="$INSTALLED/Contents/Resources/connection.json"
  else echo "Нет connection.json. Создайте пару: scripts/new-pairing.sh <IP Mac>" >&2; exit 1; fi
fi

VERSION=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["Version"])' windows-version.json)
CSPROJ_VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' windows/WindowsAudio.csproj)
[ "$VERSION" = "$CSPROJ_VERSION" ] || { echo "windows-version.json ($VERSION) != WindowsAudio.csproj ($CSPROJ_VERSION)" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$CONFIG" "$OUT/connection.json"
echo "AudioBridge $VERSION, pairing config: $CONFIG"

echo "1/5 Mac receiver"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  mac/Packet.swift mac/Discovery.swift mac/Microphone.swift mac/MicrophoneTests.swift mac/UpdateServer.swift mac/main.swift \
  -o "$OUT/AudioBridge"

echo "2/5 Icon"
swift make-icon.swift "$OUT/AudioBridge.iconset" >/dev/null
iconutil --convert icns --output "$OUT/AudioBridge.icns" "$OUT/AudioBridge.iconset"

echo "3/5 Windows sender"
(cd windows && DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet publish WindowsAudio.csproj -c Release -r win-x64 \
  -p:RuntimeFrameworkVersion=8.0.31 -o "$OUT/publish-win" -nologo -v quiet)

echo "4/5 Windows-Audio.zip"
python3 -I - "$ROOT" "$OUT" <<'PY'
import json, sys, zipfile
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
config = json.loads((out / 'connection.json').read_text())
config.pop('DownloadToken', None)  # Windows only needs the key; the token stays on the Mac
with zipfile.ZipFile(out / 'Windows-Audio.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    z.write(out / 'publish-win/WindowsAudio.exe', 'WindowsAudio.exe')
    z.writestr('connection.json', json.dumps(config))
    for name in ['Install.cmd', 'Stop.cmd', 'Disable-startup.cmd']:
        text = (root / name).read_text().replace('\r\n', '\n').replace('\n', '\r\n')
        z.writestr(name, text.encode('ascii'))
    for name in ['NAudio-LICENSE.txt', 'dotnet-LICENSE.TXT', 'dotnet-THIRD-PARTY-NOTICES.TXT']:
        z.write(root / name, name)
    z.write(root / 'WINDOWS-README.txt', 'README.txt')
PY

echo "5/5 AudioBridge.app"
APP="$OUT/AudioBridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
cp "$OUT/AudioBridge" "$APP/Contents/MacOS/AudioBridge"
cp "$OUT/AudioBridge.icns" "$OUT/connection.json" "$OUT/Windows-Audio.zip" windows-version.json "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Готово: $APP"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "local.audiobridge.receiver" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -x AudioBridge >/dev/null || break; sleep 0.1; done
  pkill -x AudioBridge 2>/dev/null || true
  if [ -d "$INSTALLED" ]; then ditto "$INSTALLED" "$OUT/previous/AudioBridge.app"; rm -rf "$INSTALLED"; fi
  ditto "$APP" "$INSTALLED"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"
  open "$INSTALLED"
  echo "Установлено и запущено: $INSTALLED (прежняя версия: $OUT/previous)"
fi
