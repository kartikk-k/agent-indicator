#!/bin/sh
# Builds build/Agent Indicator.app with the Command Line Tools (no Xcode needed).
set -eu
cd "$(dirname "$0")"

APP="build/Agent Indicator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement -framework CoreServices \
    Sources/*.swift -o "$APP/Contents/MacOS/AgentIndicator"

codesign --force --sign - "$APP"
echo "Built $APP"
