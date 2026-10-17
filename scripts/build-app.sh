#!/usr/bin/env bash
# Builds "Couch Remote.app" and the tvctl CLI into ./build.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copies the app to ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product CouchRemote
swift build -c release --product tvctl
BIN="$(swift build -c release --show-bin-path)"

APP="build/Couch Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CouchRemote" "$APP/Contents/MacOS/CouchRemote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R "$BIN"/*_TVKit.bundle "$APP/Contents/Resources/"
cp "$BIN/tvctl" build/tvctl
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Couch Remote.app"
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Couch Remote.app"
fi
echo "Built $APP and build/tvctl"
