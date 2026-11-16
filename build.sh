#!/usr/bin/env bash
# Build T3 Widget.app. Usage: ./build.sh [--install]
#   --install  copy to ~/Applications and start it at login (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/T3 Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework SwiftUI -lsqlite3 \
  Sources/T3Widget.swift -o "$APP/Contents/MacOS/T3Widget"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T3 Widget</string>
  <key>CFBundleIdentifier</key><string>local.lab.t3widget</string>
  <key>CFBundleExecutable</key><string>T3Widget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/T3 Widget.app"
  AGENT="$HOME/Library/LaunchAgents/local.lab.t3widget.plist"
  pkill -x T3Widget 2>/dev/null || true
  mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.lab.t3widget</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/T3Widget</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/local.lab.t3widget" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "Installed to $DEST and started (runs at login)."
fi
