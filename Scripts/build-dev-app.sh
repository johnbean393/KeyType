#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${KEYTYPE_DERIVED_DATA_PATH:-"$ROOT_DIR/.build/DerivedData-dev"}"
CONFIGURATION="${KEYTYPE_CONFIGURATION:-Debug}"
APP_NAME="${KEYTYPE_DEV_APP_NAME:-KeyType Dev}"
BUNDLE_IDENTIFIER="${KEYTYPE_DEV_BUNDLE_ID:-com.pattonium.KeyType.dev}"
INSTALL_PATH="${KEYTYPE_DEV_APP_PATH:-/Applications/$APP_NAME.app}"
SHOULD_LAUNCH=1

usage() {
  cat <<USAGE
Usage: Scripts/build-dev-app.sh [--no-launch]

Builds KeyType with a stable development product name and bundle identifier, then installs it at:
  $INSTALL_PATH

Environment overrides:
  KEYTYPE_DEV_APP_NAME      default: KeyType Dev
  KEYTYPE_DEV_BUNDLE_ID     default: com.pattonium.KeyType.dev
  KEYTYPE_DEV_APP_PATH      default: /Applications/KeyType Dev.app
  KEYTYPE_CONFIGURATION     default: Debug
  KEYTYPE_DERIVED_DATA_PATH default: .build/DerivedData-dev
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-launch)
      SHOULD_LAUNCH=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

KEYTYPE_SKIP_DEV_APP_INSTALL=1 xcodebuild \
  -workspace "$ROOT_DIR/KeyType.xcworkspace" \
  -scheme KeyType \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  PRODUCT_NAME="$APP_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
  build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/KeyType.app"
fi

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app was not found under $DERIVED_DATA_PATH/Build/Products/$CONFIGURATION" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/install-dev-app-from-build.sh" "$BUILT_APP"
echo "Grant Accessibility to this app once in System Settings, then rerun this script for code changes."

if [[ "$SHOULD_LAUNCH" -eq 1 ]]; then
  open -n "$INSTALL_PATH"
fi
