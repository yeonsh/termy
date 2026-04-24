#!/usr/bin/env bash
# Archive → sign → notarize → staple → DMG.
#
# One-time setup:
#   1. Copy .env.example → .env and fill in TEAM_ID + SIGNING_IDENTITY
#      (.env is gitignored).
#   2. Store Apple ID creds in login keychain under "termy-notary":
#      xcrun notarytool store-credentials "termy-notary" \
#        --apple-id <apple-id> --team-id "$TEAM_ID" \
#        --password <app-specific-password>
#
# Usage:
#   scripts/dist.sh                  # full pipeline, outputs build/dist/termy-<ver>.dmg
#   scripts/dist.sh --skip-notarize  # sign only (local testing)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Load signing config from local .env if present — gitignored, per-developer.
if [[ -f "$ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi
: "${TEAM_ID:?TEAM_ID not set — copy .env.example to .env and fill it in}"
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY not set — copy .env.example to .env and fill it in}"

KEYCHAIN_PROFILE="termy-notary"
SCHEME="termy"

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

DIST="$ROOT/build/dist"
ARCHIVE="$DIST/termy.xcarchive"
EXPORT_DIR="$DIST/export"
EXPORT_OPTS="$DIST/ExportOptions.plist"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> render ExportOptions.plist (teamID=${TEAM_ID})"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "==> xcodegen"
xcodegen generate --quiet

echo "==> archive (Release)"
xcodebuild \
    -project termy.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    archive \
    | tail -20

echo "==> export Developer ID"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    | tail -10

APP="$EXPORT_DIR/termy.app"
if [[ ! -d "$APP" ]]; then
    echo "dist.sh: exported app not found at $APP" >&2
    exit 1
fi

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/termy-${VERSION}.dmg"

echo "==> build DMG ($DMG)"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "termy ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "==> sign DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "==> skipping notarization (--skip-notarize)"
    echo "done (unnotarized): $DMG"
    exit 0
fi

echo "==> notarize (wait, may take minutes)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> gatekeeper check"
spctl --assess --type execute --verbose=4 "$APP" || true
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || true

echo "==> sparkle sign + appcast"
SPARKLE_BIN="$ROOT/scripts/vendor/sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "dist.sh: Sparkle tools missing at $SPARKLE_BIN" >&2
    echo "         run scripts/setup-sparkle.sh first" >&2
    exit 1
fi

# Preflight: SUPublicEDKey must be in the built app's Info.plist. Without it,
# every shipped client silently rejects every signed update.
if ! /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "dist.sh: SUPublicEDKey is missing from $APP/Contents/Info.plist" >&2
    echo "         run scripts/vendor/sparkle/bin/generate_keys --account termy," >&2
    echo "         paste the public key into project.yml, rerun." >&2
    exit 1
fi

APPCAST_STAGING="$DIST/appcast-staging"
rm -rf "$APPCAST_STAGING"
mkdir -p "$APPCAST_STAGING"
cp "$DMG" "$APPCAST_STAGING/"

# Render release-notes HTML for Sparkle and markdown for the GitHub release
# body. The HTML stem must match the DMG stem — generate_appcast pairs each
# archive with the same-stem .html. Soft-fail: a missing description is not
# a release blocker.
CHANGELOG_MD="$ROOT/CHANGELOG.md"
if [[ -f "$CHANGELOG_MD" ]]; then
    python3 "$ROOT/scripts/render-release-notes.py" \
        --version "$VERSION" --format html \
        --input "$CHANGELOG_MD" \
        --output "$APPCAST_STAGING/termy-${VERSION}.html" \
        || echo "dist.sh: release-notes HTML render failed; continuing without Sparkle description"
    python3 "$ROOT/scripts/render-release-notes.py" \
        --version "$VERSION" --format markdown \
        --input "$CHANGELOG_MD" \
        --output "$DIST/release-notes.md" \
        || echo "dist.sh: release-notes markdown render failed; publish.sh will fall back to CHANGELOG.md"
fi

: "${GITHUB_REPO:?GITHUB_REPO not set — copy .env.example to .env and fill it in}"

"$SPARKLE_BIN/generate_appcast" \
    --account termy \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/" \
    --link "https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}" \
    "$APPCAST_STAGING"

mv "$APPCAST_STAGING/appcast.xml" "$DIST/appcast.xml"
echo "==> appcast ready at $DIST/appcast.xml"

echo "done: $DMG  (v${VERSION} build ${BUILD})"
