#!/bin/zsh
# Builds ChargeGuard in Release and packages it as a drag-to-install DMG.
#
#   Scripts/make-dmg.sh                 -> dist/ChargeGuard-<version>.dmg
#   NOTARY_PROFILE=myprofile Scripts/make-dmg.sh
#       also notarizes and staples (needs a Developer ID Application certificate and
#       `xcrun notarytool store-credentials myprofile` done once).
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/App/Info.plist)
DIST=$ROOT/dist
STAGE=$DIST/stage
DMG=$DIST/ChargeGuard-$VERSION.dmg
APP=build/Build/Products/Release/ChargeGuard.app

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Building Release"
xcodebuild -project ChargeGuard.xcodeproj -scheme ChargeGuard -configuration Release \
    -destination "generic/platform=macOS" ONLY_ACTIVE_ARCH=NO \
    -derivedDataPath build -allowProvisioningUpdates build -quiet

echo "==> Verifying signatures"
codesign --verify --deep --strict "$APP"
for binary in "$APP" "$APP/Contents/MacOS/ChargeGuardHelper"; do
    codesign -dv "$binary" 2>&1 | grep -E "^(Identifier|TeamIdentifier)=" | sed "s|^|    $(basename $binary): |"
done

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ChargeGuard.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "ChargeGuard $VERSION" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet
rm -rf "$STAGE"

# Sign the disk image itself with the same identity as the app.
# Resolve it to a SHA-1 so a revoked duplicate with the same name can't make it ambiguous.
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(.*\)$/\1/p' | head -1)
IDENTITY=$(security find-identity -v -p codesigning | grep -F "\"$AUTHORITY\"" | grep -v REVOKED | awk '{print $2}' | head -1)
codesign --sign "$IDENTITY" --timestamp=none "$DMG"

if [[ -n ${NOTARY_PROFILE:-} ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
