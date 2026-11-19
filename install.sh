#!/bin/bash
# Builds Claude Account Switcher from source, signs it for this Mac only, and installs it.
# Usage: ./install.sh            (installs to ~/Applications and opens it)
#        ./install.sh --build    (only builds build/Claude Account Switcher.app)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Account Switcher"
APP="build/$APP_NAME.app"
ICON_VARIANT="${ICON_VARIANT:-1}"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift was not found. Install Xcode or the Command Line Tools (xcode-select --install), then run this again."
  exit 1
fi

echo "Building…"
swift build -c release --product ClaudeSwitcher
BIN="$(swift build -c release --show-bin-path)/ClaudeSwitcher"

echo "Making the app…"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/step0"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp data/login-set.json "$APP/Contents/Resources/login-set.json"
cp scripts/step0/step0.sh scripts/step0/snapshot.py scripts/step0/analyze.py "$APP/Contents/Resources/step0/"
swift scripts/make-icon.swift "$ICON_VARIANT" build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad hoc signature: fine for your own Mac, no Apple developer account needed.
codesign --force --deep --sign - --timestamp=none "$APP"
echo "Built $APP"

[ "${1:-}" = "--build" ] && exit 0

echo "Installing…"
pkill -x ClaudeSwitcher 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
ditto "$APP" "$HOME/Applications/$APP_NAME.app"
open "$HOME/Applications/$APP_NAME.app"
echo "Installed to ~/Applications/$APP_NAME.app — look for the two-arrows icon in the menu bar."
