#!/bin/zsh
set -e

# Build, sign, notarize, and publish a KeyType release, then update the Sparkle appcast and cut a
# GitHub release. Run it from anywhere:
#
#     ./Scripts/release.sh
#
# Prerequisites (one-time):
#   - A Developer ID Application certificate in the login keychain (Team KM2C4ZAVPJ).
#   - A notarytool keychain profile named "development"
#       (xcrun notarytool store-credentials development --apple-id ... --team-id KM2C4ZAVPJ).
#   - DropDMG with an "App Distribution" configuration.
#   - The Sparkle CLI tools (sign_update) — see SPARKLE_BIN in prepareRelease.sh. The matching
#     EdDSA public key is embedded in the app via INFOPLIST_KEY_SUPublicEDKey.
#   - gh (GitHub CLI) authenticated against the KeyType repo.
#   - GitHub Pages serving the repo's /docs folder so the appcast is reachable at SUFeedURL.
#
# Before releasing, bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project; the
# script warns if the metadata hasn't changed since the last tag.


# Configuration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PATH="$(dirname "$SCRIPT_DIR")"

APP_NAME="KeyType"
PROJECT="$REPO_PATH/KeyType.xcodeproj"
SCHEME="KeyType"
OUTPUT_DIR="/Users/bj/Desktop/Personal/Development/App Installers/KeyType"
ARCHIVE_DIR="/Users/bj/Desktop/Personal/Development/App Archives/KeyType"
REPO_URL="https://github.com/johnbean393/KeyType"
MIN_OS="14.0"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
APPCAST_PATH="$REPO_PATH/docs/appcast.xml"

mkdir -p "$OUTPUT_DIR" "$ARCHIVE_DIR"

extract_release_metadata_from_project() {
    perl -ne '
        if (!$build && /CURRENT_PROJECT_VERSION = ([^;]+);/) {
            $build = $1;
            $build =~ s/^"|"$//g;
        }
        if (!$version && /MARKETING_VERSION = "?([^";]+)"?;/) {
            $version = $1;
        }
        if ($version && $build) {
            print "$version\t$build\n";
            exit;
        }
    '
}

load_last_release_metadata() {
    local tag="$1"

    [ -z "$tag" ] && return 0

    git -C "$REPO_PATH" show "$tag:KeyType.xcodeproj/project.pbxproj" 2>/dev/null | extract_release_metadata_from_project
}

confirm_release_metadata_bump() {
    local current_version="$1"
    local current_build="$2"
    local last_tag="$3"
    local last_version="$4"
    local last_build="$5"
    local -a issues=()

    [ -z "$last_tag" ] || [ -z "$last_version" ] || [ -z "$last_build" ] && return 0

    if [ "$current_version" = "$last_version" ]; then
        issues+=("version is still $current_version")
    fi

    if [[ "$current_build" == <-> && "$last_build" == <-> ]]; then
        if (( current_build < last_build )); then
            issues+=("build $current_build is older than the last release build $last_build")
        elif (( current_build == last_build )); then
            issues+=("build is still $current_build")
        fi
    elif [ "$current_build" = "$last_build" ]; then
        issues+=("build is still $current_build")
    fi

    [ ${#issues[@]} -eq 0 ] && return 0

    echo "\nWarning: release metadata has not been bumped since the last release ($last_tag)."
    echo "Last release: version $last_version, build $last_build"
    echo "Current release: version $current_version, build $current_build"
    for issue in "${issues[@]}"; do
        echo "- $issue"
    done
    echo -n "Proceed anyway? (y/N): "
    read CONFIRM_BUMP

    if [ "$CONFIRM_BUMP" != "y" ] && [ "$CONFIRM_BUMP" != "Y" ]; then
        echo "Release cancelled."
        exit 0
    fi
}


# Step 1: Build and Archive

echo "Building $APP_NAME"
git -C "$REPO_PATH" fetch origin --tags 2>/dev/null || true
ARCHIVE_PATH="$ARCHIVE_DIR/$APP_NAME.xcarchive"

# Clean previous archive
rm -rf "$ARCHIVE_PATH"

echo "\n[1/7] Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet


# Step 2: Export signed .app

echo "\n[2/7] Exporting signed app..."
EXPORT_DIR="$ARCHIVE_DIR/Export"
rm -rf "$EXPORT_DIR"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

# Get version info
VERSION_NUM=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILD_NUM=$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)
RELEASE_TAG="v${VERSION_NUM}.0"
LAST_TAG=$(git -C "$REPO_PATH" describe --tags --abbrev=0 2>/dev/null || echo "")
LAST_RELEASE_METADATA=$(load_last_release_metadata "$LAST_TAG" || true)
LAST_RELEASE_VERSION=""
LAST_RELEASE_BUILD=""
if [ -n "$LAST_RELEASE_METADATA" ]; then
    IFS=$'\t' read -r LAST_RELEASE_VERSION LAST_RELEASE_BUILD <<< "$LAST_RELEASE_METADATA"
fi

echo "Releasing $APP_NAME $VERSION_NUM (build $BUILD_NUM) - tag: $RELEASE_TAG"
confirm_release_metadata_bump "$VERSION_NUM" "$BUILD_NUM" "$LAST_TAG" "$LAST_RELEASE_VERSION" "$LAST_RELEASE_BUILD"


# Step 3: Notarize the .app

echo "\n[3/7] Notarizing app..."

# Create a zip of the app for notarization
APP_ZIP="$EXPORT_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

# Submit for notarization and wait
xcrun notarytool submit "$APP_ZIP" --keychain-profile "development" --wait

# Staple the notarization ticket to the app
xcrun stapler staple "$APP_PATH"

# Clean up the zip
rm -f "$APP_ZIP"

echo "App notarization complete."


# Step 4: Create DMG, notarize DMG, and sign with Sparkle

echo "\n[4/7] Creating DMG, notarizing, and signing..."
sh "$SCRIPT_DIR/prepareRelease.sh" \
    --app "$APP_PATH" \
    --output "$OUTPUT_DIR" \
    --repo-url "$REPO_URL" \
    --min-os-version "$MIN_OS" | tee /tmp/keytype_sparkle_output.txt

# Extract Sparkle signature and file length from the prepareRelease output
ED_SIGNATURE=$(grep "sparkle:edSignature" /tmp/keytype_sparkle_output.txt | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
FILE_LENGTH=$(grep "length=" /tmp/keytype_sparkle_output.txt | sed 's/.*length="\([^"]*\)".*/\1/')


# Step 5: Update appcast.xml

echo "\n[5/7] Updating docs/appcast.xml..."
PUB_DATE=$(date +"%a, %d %b %Y %H:%M:%S %z")
DMG_FILENAME="$APP_NAME.$VERSION_NUM.dmg"

NEW_ITEM="        <item>\\
            <title>$VERSION_NUM</title>\\
            <pubDate>$PUB_DATE</pubDate>\\
            <sparkle:version>$BUILD_NUM</sparkle:version>\\
            <sparkle:shortVersionString>$VERSION_NUM</sparkle:shortVersionString>\\
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>\\
            <enclosure url=\"$REPO_URL/releases/download/$RELEASE_TAG/$DMG_FILENAME\" sparkle:edSignature=\"$ED_SIGNATURE\" length=\"$FILE_LENGTH\" type=\"application/octet-stream\"/>\\
        </item>"

sed -i '' "/<title>$APP_NAME<\/title>/a\\
$NEW_ITEM
" "$APPCAST_PATH"


# Step 6: Rename DMG to match the release URL pattern

echo "\n[6/7] Renaming DMG..."
DMG_NAME="$APP_NAME $VERSION_NUM"

if [ ! -f "$OUTPUT_DIR/$DMG_NAME.dmg" ]; then
    echo "Error: DMG file not found at $OUTPUT_DIR/$DMG_NAME.dmg"
    echo "The DMG creation may have failed. Please check the output above."
    exit 1
fi

mv "$OUTPUT_DIR/$DMG_NAME.dmg" "$OUTPUT_DIR/$DMG_FILENAME"

if [ ! -f "$OUTPUT_DIR/$DMG_FILENAME" ]; then
    echo "Error: Failed to rename DMG to $OUTPUT_DIR/$DMG_FILENAME"
    exit 1
fi

echo "DMG ready: $OUTPUT_DIR/$DMG_FILENAME"


# Step 7: Git commit appcast and cut the GitHub release

echo "\n[7/7] Creating GitHub release..."
cd "$REPO_PATH"

# Extract feat: and fix: commit messages since the last tag
if [ -n "$LAST_TAG" ]; then
    FEAT_COMMITS=$(git log "$LAST_TAG"..HEAD --oneline --grep="^feat:" --format="%s" | sed 's/^feat: /- /')
    FIX_COMMITS=$(git log "$LAST_TAG"..HEAD --oneline --grep="^fix:" --format="%s" | sed 's/^fix: /- /')
else
    FEAT_COMMITS=$(git log --oneline --grep="^feat:" --format="%s" | sed 's/^feat: /- /')
    FIX_COMMITS=$(git log --oneline --grep="^fix:" --format="%s" | sed 's/^fix: /- /')
fi

# Build release notes
if [ -n "$LAST_TAG" ]; then
    RELEASE_NOTES="# Update

## New Features
${FEAT_COMMITS:-No new features in this release.}

## Bug Fixes
${FIX_COMMITS:-No bug fixes in this release.}

## Requirements

- macOS Sonoma (14.0) or later
- Apple Silicon Mac recommended for on-device model inference"
else
    RELEASE_NOTES="# KeyType

On-device, system-wide tab autocomplete for macOS.

## Features

- System-wide ghost-text completions accepted with Tab
- Fully on-device prediction with a local LLM (no network calls)
- Short, cursor-anchored continuations that prefer silence over a wrong guess
- App-aware insertion and overlay behavior
- Private by default: clipboard, screen/OCR, and writing-history context are opt-in

## Requirements

- macOS Sonoma (14.0) or later
- Apple Silicon Mac recommended for on-device model inference"
fi

# Show summary and ask for confirmation
echo "\nReady to upload release"
echo "Version: $VERSION_NUM"
echo "Tag: $RELEASE_TAG"
echo "DMG: $OUTPUT_DIR/$DMG_FILENAME"
echo "\nRelease Notes Preview:"
echo "$RELEASE_NOTES"
echo -n "Proceed with upload? (y/n): "
read CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Release cancelled by user."
    exit 0
fi

# Commit and push the updated appcast
git add docs/appcast.xml
git commit -m "Release $VERSION_NUM"
git push

# Create the GitHub release with the DMG attached
gh release create "$RELEASE_TAG" \
    "$OUTPUT_DIR/$DMG_FILENAME" \
    --title "$VERSION_NUM" \
    --notes "$RELEASE_NOTES"


# Done!

echo "\nRelease $VERSION_NUM complete!"
echo "DMG: $OUTPUT_DIR/$DMG_FILENAME"
echo "GitHub: $REPO_URL/releases/tag/$RELEASE_TAG"
echo "Appcast: https://johnbean393.github.io/KeyType/appcast.xml"
