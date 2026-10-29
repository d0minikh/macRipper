#!/bin/zsh
# Builds MacRipper.app into ./build with SwiftPM (release, ad-hoc signed) – no Xcode needed.
# For signing with your Apple Developer account, build MacRipper.xcodeproj in Xcode instead.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer Xcode's toolchain when it is installed; the Command Line Tools lack some compiler plugins.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Keep in sync with the build settings in MacRipper.xcodeproj.
BUNDLE_ID="de.macripper.macRipper"
MARKETING_VERSION="1.0.0"
BUILD_NUMBER="3"
DEPLOYMENT_TARGET="26.0"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacRipper"
APP="build/MacRipper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacRipper"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/\$(PRODUCT_NAME)/MacRipper/" \
    -e "s/\$(EXECUTABLE_NAME)/MacRipper/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOYMENT_TARGET/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
