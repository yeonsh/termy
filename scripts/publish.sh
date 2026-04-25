#!/usr/bin/env bash
# Publish a finished DMG + appcast to GitHub Releases and termy.nugo.cc.
#
# Preconditions:
#   - scripts/dist.sh completed successfully (no --skip-notarize)
#   - build/dist/termy-<v>.dmg and build/dist/appcast.xml exist
#   - gh CLI authenticated (gh auth status)
#   - $PAGES_REPO_PATH contains a clone of the termy-updates Pages repo
#
# Usage:
#   scripts/publish.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [[ -f "$ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

: "${GITHUB_REPO:?GITHUB_REPO not set — copy .env.example to .env and fill it in}"

PAGES="${PAGES_REPO_PATH:-$ROOT/../termy-updates}"
if [[ ! -d "$PAGES/.git" ]]; then
    echo "publish.sh: no Pages repo at $PAGES" >&2
    echo "  clone the termy-updates repo there, or set PAGES_REPO_PATH in .env" >&2
    exit 1
fi

DIST="$ROOT/build/dist"
DMG="$(ls "$DIST"/termy-*.dmg 2>/dev/null | head -n1 || true)"
APPCAST="$DIST/appcast.xml"
if [[ -z "${DMG:-}" || ! -f "$DMG" || ! -f "$APPCAST" ]]; then
    echo "publish.sh: run scripts/dist.sh first — missing DMG or appcast.xml under $DIST" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DIST/export/termy.app/Contents/Info.plist")"
TAG="v${VERSION}"
# Prefer the per-version release notes dist.sh generated; fall back to the
# full CHANGELOG. A user-supplied RELEASE_NOTES_FILE wins over both.
if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    NOTES_FILE="$RELEASE_NOTES_FILE"
elif [[ -f "$DIST/release-notes.md" ]]; then
    NOTES_FILE="$DIST/release-notes.md"
else
    NOTES_FILE="$ROOT/CHANGELOG.md"
fi

echo "==> gh auth check"
gh auth status >/dev/null

echo "==> create GitHub release $TAG (DMG upload)"
gh release create "$TAG" "$DMG" \
    --repo "$GITHUB_REPO" \
    --title "termy ${VERSION}" \
    --notes-file "$NOTES_FILE"

echo "==> publish appcast to Pages repo at $PAGES"
cp "$APPCAST" "$PAGES/appcast.xml"

echo "==> rewrite hero download CTA to v${VERSION} in index.html / index.en.html"
for f in "$PAGES/index.html" "$PAGES/index.en.html"; do
    sed -i '' -E \
        -e "s|releases/download/v[0-9]+\.[0-9]+\.[0-9]+/termy-[0-9]+\.[0-9]+\.[0-9]+\.dmg|releases/download/v${VERSION}/termy-${VERSION}.dmg|g" \
        -e "s|Download v[0-9]+\.[0-9]+\.[0-9]+ \(3 MB DMG\)|Download v${VERSION} (3 MB DMG)|g" \
        "$f"
    if ! grep -q "termy-${VERSION}\.dmg" "$f" || ! grep -q "Download v${VERSION} (3 MB DMG)" "$f"; then
        echo "publish.sh: version rewrite failed in $f — pattern not found" >&2
        exit 1
    fi
done

git -C "$PAGES" add appcast.xml index.html index.en.html
git -C "$PAGES" commit -m "termy ${VERSION}"
git -C "$PAGES" push

echo "done:"
echo "  release: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "  appcast: https://termy.nugo.cc/appcast.xml (Pages deploy ~30s)"
