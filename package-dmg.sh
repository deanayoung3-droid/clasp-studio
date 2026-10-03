#!/bin/zsh
# The approved app is packaged with a Retina background and Finder icon layout.
set -euo pipefail
ROOT=${0:A:h}
APP="$ROOT/../Clasp Studio.app"
STAGE=$(mktemp -d /private/tmp/clasp-studio-dmg.XXXXXX)
MOUNT="$STAGE/mount"
DMG="$ROOT/../Clasp Studio.dmg"
cleanup() {
  if mount | grep -Fq "on $MOUNT "; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/content/.background" "$MOUNT"
ditto --norsrc --noextattr "$APP" "$STAGE/content/Clasp Studio.app"
xattr -cr "$STAGE/content/Clasp Studio.app"
codesign --force --deep --sign - "$STAGE/content/Clasp Studio.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/content/Clasp Studio.app"
ln -s /Applications "$STAGE/content/Applications"
cp "$ROOT/Packaging/Installer.tiff" "$STAGE/content/.background/Installer.tiff"
hdiutil create -volname "Clasp Studio" -fs HFS+ -srcfolder "$STAGE/content" -size 64m -ov -format UDRW "$STAGE/installer-rw.dmg"
hdiutil attach "$STAGE/installer-rw.dmg" -nobrowse -noautoopen -mountpoint "$MOUNT"
# Set PACKAGING_PYTHONPATH for an isolated --target dependency installation.
PYTHONPATH="${PACKAGING_PYTHONPATH:-}" python3 "$ROOT/Packaging/finder_layout.py" "$MOUNT"
cp "$ROOT/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
# Finder may attach harmless metadata after opening; the disk image starts clean.
xattr -cr "$MOUNT/Clasp Studio.app"
codesign --verify --deep --strict --verbose=2 "$MOUNT/Clasp Studio.app"
hdiutil detach "$MOUNT"
hdiutil convert "$STAGE/installer-rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
hdiutil verify "$DMG"
print "Created non-notarized DMG: $DMG"
