#!/bin/bash
# Builds Nits.app (ad-hoc signed) into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Nits.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Nits "$APP/Contents/MacOS/Nits"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Hardened runtime: blocks injected libraries (DYLD_INSERT_LIBRARIES) and unsigned code, so another
# process can't load its code into Nits and then trigger Nits' admin password prompt.
codesign --force --options runtime --entitlements Resources/Nits.entitlements --sign - "$APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Nits.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Nits.app"
else
  echo "Built $APP"
fi
