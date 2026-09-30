#!/bin/sh
# Builds a universal, Developer ID–signed, notarized and stapled DMG:
#   build/Agent Indicator.dmg
#
#   NOTARY_PROFILE=<notarytool keychain profile> ./release.sh
#
# SIGN_IDENTITY defaults to your "Developer ID Application" certificate.
# Create a notary profile once with `xcrun notarytool store-credentials`.
set -eu
cd "$(dirname "$0")"

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NAME="Agent Indicator"
APP="build/$NAME.app"
DMG="build/$NAME.dmg"

echo "==> Building universal binary"
rm -rf build && mkdir -p "$APP/Contents/MacOS" build/obj
cp Resources/Info.plist "$APP/Contents/Info.plist"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -framework AppKit -framework ServiceManagement -framework CoreServices \
        Sources/*.swift -o "build/obj/AgentIndicator-$arch"
done
lipo -create build/obj/AgentIndicator-* -output "$APP/Contents/MacOS/AgentIndicator"
rm -rf build/obj

echo "==> Signing app ($SIGN_IDENTITY)"
codesign --force --timestamp --options runtime \
    --entitlements Resources/AgentIndicator.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating DMG"
STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "==> Notarizing (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying Gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
