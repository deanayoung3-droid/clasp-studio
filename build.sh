#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h}
BUILD="$ROOT/.build"
DELIVERY_DIR="${CLASP_DELIVERY_DIR:-$ROOT/..}"
mkdir -p "$DELIVERY_DIR"
DELIVERY="$DELIVERY_DIR/Clasp Studio.app"
APP_STAGE=$(mktemp -d /private/tmp/clasp-studio-build.XXXXXX)
trap 'rm -rf "$APP_STAGE"' EXIT
APP="$APP_STAGE/Clasp Studio.app"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/module-cache" "$ROOT"/Sources/*.swift "$ROOT"/Tests/*.swift -o "$BUILD/ClaspStudio-arm64" -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework CoreImage -framework PDFKit -framework Speech -framework MetalKit -framework Metal -framework Security -framework CryptoKit -framework WebKit
if [[ "${1:-}" == "--universal" ]]; then
  xcrun swiftc -swift-version 5 -O -target x86_64-apple-macosx14.0 -module-cache-path "$BUILD/module-cache-x86" "$ROOT"/Sources/*.swift "$ROOT"/Tests/*.swift -o "$BUILD/ClaspStudio-x86_64" -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework CoreImage -framework PDFKit -framework Speech -framework MetalKit -framework Metal -framework Security -framework CryptoKit -framework WebKit
  xcrun lipo -create "$BUILD/ClaspStudio-arm64" "$BUILD/ClaspStudio-x86_64" -output "$APP/Contents/MacOS/ClaspStudio"
else
  cp "$BUILD/ClaspStudio-arm64" "$APP/Contents/MacOS/ClaspStudio"
fi
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 "$ROOT/Helpers/UpdateInstaller.swift" -o "$BUILD/UpdateInstaller-arm64" -framework AppKit
if [[ "${1:-}" == "--universal" ]]; then
  xcrun swiftc -swift-version 5 -O -target x86_64-apple-macosx14.0 "$ROOT/Helpers/UpdateInstaller.swift" -o "$BUILD/UpdateInstaller-x86_64" -framework AppKit
  xcrun lipo -create "$BUILD/UpdateInstaller-arm64" "$BUILD/UpdateInstaller-x86_64" -output "$APP/Contents/MacOS/ClaspUpdateInstaller"
else
  cp "$BUILD/UpdateInstaller-arm64" "$APP/Contents/MacOS/ClaspUpdateInstaller"
fi
codesign --force --sign - "$APP/Contents/MacOS/ClaspUpdateInstaller"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
xcrun actool "$ROOT/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$BUILD/icon-info.plist" --output-format human-readable-text
cp "$ROOT"/Resources/* "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto --norsrc --noextattr "$APP" "$DELIVERY"
# Finder may add icon metadata immediately after an app copy in Documents.
# Verify the delivery after stripping it, with a bounded retry for that race.
DELIVERY_VERIFIED=0
for VERIFY_ATTEMPT in 1 2 3; do
  xattr -cr "$DELIVERY"
  if codesign --verify --deep --strict --verbose=2 "$DELIVERY"; then DELIVERY_VERIFIED=1; break; fi
done
[[ "$DELIVERY_VERIFIED" == 1 ]]
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DELIVERY_DIR/Clasp Studio Preview App.zip"
print "Built $DELIVERY and verified the app archive"
