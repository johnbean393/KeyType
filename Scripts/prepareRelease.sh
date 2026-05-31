#!/bin/zsh

# Create a notarized, stapled DMG from an exported .app and emit a signed Sparkle <item>.
#
# Usage:
#   prepareRelease.sh --app /path/to/Exported.app --output /dmg/dir \
#       --repo-url https://github.com/user/repo [--min-os-version 14.0]
#
# Requires: DropDMG (with an "App Distribution" config), a notarytool keychain profile named
# "development", and the Sparkle command-line tools (sign_update). Override SPARKLE_BIN if your
# Sparkle tools live elsewhere.

usage() {
  echo "Usage: $0 --app /path/to/exported/app --output /path/to/directory --repo-url https://github.com/username/repo --min-os-version 14.0"
  exit 1
}

# Initialize variables
APP_PATH=""
DMG_DIRECTORY=""
REPO_URL=""
MIN_OS="14.0"

# Where the Sparkle command-line tools (sign_update, generate_keys, ...) live.
SPARKLE_BIN="${SPARKLE_BIN:-/Users/bj/Desktop/Personal/Development/Swift Packages/Sparkle-for-Swift-Package-Manager/bin}"

# Parse command-line arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      shift
      APP_PATH="$1"
      ;;
    --output)
      shift
      DMG_DIRECTORY="$1"
      ;;
    --repo-url)
      shift
      REPO_URL="$1"
      ;;
    --min-os-version)
      shift
      MIN_OS="$1"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

# Check if all required arguments are provided
if [ -z "$APP_PATH" ] || [ -z "$DMG_DIRECTORY" ] || [ -z "$REPO_URL" ]; then
  usage
fi

# Remove trailing slashes (/)
REPO_URL=${REPO_URL%/}
DMG_DIRECTORY=${DMG_DIRECTORY%/}

# Make sure the output directory exists
mkdir -p "$DMG_DIRECTORY"

# Get versioning
VERSION_NUM=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILD_NUM=$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)

# Formulate the name of the DMG
APP_NAME=$(basename "$APP_PATH" .app)
DMG_NAME="$APP_NAME $VERSION_NUM"

# Remove existing disk image if exists and wait 5 seconds for delete
rm -f "$DMG_DIRECTORY/$DMG_NAME.dmg"; sleep 5

# Trigger the macOS Automation permission prompt once before invoking DropDMG.
osascript -e 'tell application "DropDMG" to beep' >/dev/null 2>&1 || true

# Create a disk image from the app
DMG_PATH=$(dropdmg --config-name "App Distribution" "$APP_PATH" --destination "$DMG_DIRECTORY")

# Notarize the disk image
xcrun notarytool submit "$DMG_PATH" --keychain-profile "development" --wait

# Staple the notarization ticket
xcrun stapler staple "$DMG_PATH"

# Sign the disk image, while saving the outputted signature (sparkle:edSignature + length)
cd "$SPARKLE_BIN"
ED_SIGNATURE=$(./sign_update "$DMG_PATH")

# Get release date
FULL_PUB_DATE=$(date +"%a, %d %b %Y %H:%M:%S %z")

# Put together appcast.xml entry (the enclosure line carries both edSignature and length)
cat <<EOF
<item>
	<title>$VERSION_NUM</title>
	<pubDate>$FULL_PUB_DATE</pubDate>
	<sparkle:version>$BUILD_NUM</sparkle:version>
	<sparkle:shortVersionString>$VERSION_NUM</sparkle:shortVersionString>
	<sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
	<enclosure url="$REPO_URL/releases/download/$VERSION_NUM/$APP_NAME.$VERSION_NUM.dmg"
	$ED_SIGNATURE
	type="application/octet-stream" />
</item>
EOF

# Open output directory
open "$DMG_DIRECTORY"
