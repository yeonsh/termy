#!/usr/bin/env bash
# Bump four version fields in project.yml atomically, then regenerate
# termy.xcodeproj. Stages project.yml but does not commit — operator reviews
# the diff, updates CHANGELOG.md, and commits manually.
#
# Usage:  scripts/bump-version.sh <new-semver>
# Example: scripts/bump-version.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [[ $# -ne 1 ]]; then
    echo "usage: scripts/bump-version.sh <new-semver>" >&2
    exit 2
fi
NEW_VERSION="$1"

# Validate semver shape (major.minor.patch, digits only).
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "bump-version.sh: '$NEW_VERSION' is not a valid semver (expected N.N.N)" >&2
    exit 2
fi

PROJECT_YML="$ROOT/project.yml"
[[ -f "$PROJECT_YML" ]] || { echo "no project.yml at $PROJECT_YML" >&2; exit 1; }

# Read current values. Use anchored grep to avoid picking up similar keys.
# `[[:space:]]+` is portable (BSD grep/sed on macOS don't honour \s).
CURRENT_VERSION="$(grep -E '^[[:space:]]+CFBundleShortVersionString:' "$PROJECT_YML" \
    | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
CURRENT_BUILD="$(grep -E '^[[:space:]]+CFBundleVersion:' "$PROJECT_YML" \
    | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"

[[ -n "$CURRENT_VERSION" && -n "$CURRENT_BUILD" ]] \
    || { echo "bump-version.sh: could not parse current version from project.yml" >&2; exit 1; }

# Semver compare — refuse downgrade. Sort -V does the right thing for N.N.N.
LOWEST="$(printf '%s\n%s\n' "$CURRENT_VERSION" "$NEW_VERSION" | sort -V | head -n1)"
if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "bump-version.sh: $NEW_VERSION is already the current version" >&2
    exit 1
fi
if [[ "$LOWEST" == "$NEW_VERSION" ]]; then
    echo "bump-version.sh: $NEW_VERSION is lower than current $CURRENT_VERSION" >&2
    exit 1
fi

NEW_BUILD="$((CURRENT_BUILD + 1))"

echo "==> bumping $CURRENT_VERSION (build $CURRENT_BUILD) -> $NEW_VERSION (build $NEW_BUILD)"

# In-place rewrites, each anchored to a line prefix so we only touch the
# intended fields. BSD sed on macOS: -i '' is the no-backup form.
sed -i '' -E \
    -e "s/^([[:space:]]+CFBundleShortVersionString:[[:space:]]*)\"[^\"]+\"/\1\"$NEW_VERSION\"/" \
    -e "s/^([[:space:]]+CFBundleVersion:[[:space:]]*)\"[^\"]+\"/\1\"$NEW_BUILD\"/" \
    -e "s/^([[:space:]]+MARKETING_VERSION:[[:space:]]*)\"[^\"]+\"/\1\"$NEW_VERSION\"/" \
    -e "s/^([[:space:]]+CURRENT_PROJECT_VERSION:[[:space:]]*)\"[^\"]+\"/\1\"$NEW_BUILD\"/" \
    "$PROJECT_YML"

# Sanity — all four fields should now reflect the new values.
COUNT="$(grep -cE "\"$NEW_VERSION\"|\"$NEW_BUILD\"" "$PROJECT_YML" || true)"
if [[ "$COUNT" -lt 4 ]]; then
    echo "bump-version.sh: rewrite did not produce the expected fields — revert project.yml and investigate" >&2
    exit 1
fi

echo "==> xcodegen"
xcodegen generate --quiet

git add "$PROJECT_YML"
echo "done. project.yml staged. Review diff, update CHANGELOG.md, then commit."
echo "Next: git diff --staged && \$EDITOR CHANGELOG.md"
