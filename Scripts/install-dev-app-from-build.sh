#!/usr/bin/env bash
set -euo pipefail

SOURCE_APP="${1:-${TARGET_BUILD_DIR:-}/${FULL_PRODUCT_NAME:-}}"
DEST_APP="${KEYTYPE_DEV_APP_PATH:-/Applications/KeyType Dev.app}"
DEV_APP_NAME="${KEYTYPE_DEV_APP_NAME:-KeyType Dev}"
DEV_BUNDLE_ID="${KEYTYPE_DEV_BUNDLE_ID:-com.pattonium.KeyType.dev}"

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  echo "warning: KeyType dev install skipped; source app not found at $SOURCE_APP"
  exit 0
fi

case "$SOURCE_APP" in
  *.app) ;;
  *) exit 0 ;;
esac

DEST_PARENT="$(dirname "$DEST_APP")"
mkdir -p "$DEST_PARENT"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

INFO_PLIST="$DEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DEV_APP_NAME" "$INFO_PLIST"
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DEV_APP_NAME" "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DEV_APP_NAME" "$INFO_PLIST"
fi

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(codesign -dvv "$SOURCE_APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
    | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$DEV_BUNDLE_ID" --options runtime --preserve-metadata=entitlements "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"

PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")"
SIGNED_BUNDLE_ID="$(codesign -dv "$DEST_APP" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$PLIST_BUNDLE_ID" != "$DEV_BUNDLE_ID" || "$SIGNED_BUNDLE_ID" != "$DEV_BUNDLE_ID" ]]; then
  echo "error: installed dev app identity mismatch" >&2
  echo "  Info.plist: $PLIST_BUNDLE_ID" >&2
  echo "  codesign:   $SIGNED_BUNDLE_ID" >&2
  echo "  expected:   $DEV_BUNDLE_ID" >&2
  exit 1
fi

touch "$DEST_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "Installed $DEST_APP ($DEV_BUNDLE_ID)"
