#!/usr/bin/env bash
# One-time installer for Sparkle's CLI tools and the Python `markdown` module.
# Downloads a pinned tarball, verifies SHA-256, extracts bin/ into
# scripts/vendor/sparkle/bin/. Idempotent — safe to re-run.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SPARKLE_VERSION="2.6.4"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
# Replace on first install: run this script, let it fail, copy the "actual:"
# value it prints into SPARKLE_SHA256 below, re-run. Commit the resulting
# SHA-256. All future developers verify against that same hash.
SPARKLE_SHA256="50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"

VENDOR="$ROOT/scripts/vendor/sparkle"
BIN="$VENDOR/bin"

if [[ -x "$BIN/sign_update" && -x "$BIN/generate_appcast" && -x "$BIN/generate_keys" ]]; then
    echo "setup-sparkle.sh: tools already present at $BIN"
else
    echo "==> download Sparkle ${SPARKLE_VERSION}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "$SPARKLE_URL" -o "$TMP/sparkle.tar.xz"

    echo "==> verify SHA-256"
    ACTUAL="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"
    if [[ "$ACTUAL" != "$SPARKLE_SHA256" ]]; then
        echo "setup-sparkle.sh: SHA-256 mismatch" >&2
        echo "  expected: $SPARKLE_SHA256" >&2
        echo "  actual:   $ACTUAL" >&2
        echo "  Update SPARKLE_SHA256 in this script if you intentionally bumped the version." >&2
        exit 1
    fi

    echo "==> extract to $VENDOR"
    rm -rf "$VENDOR"
    mkdir -p "$VENDOR"
    tar -xJf "$TMP/sparkle.tar.xz" -C "$VENDOR" --strip-components=1
    [[ -x "$BIN/sign_update" ]] || { echo "bin/ not found in tarball" >&2; exit 1; }
fi

echo "==> install Python markdown module (user site)"
if python3 -c "import markdown" 2>/dev/null; then
    echo "setup-sparkle.sh: python3 markdown module already installed"
else
    # --break-system-packages needed on Python 3.11+ with PEP 668.
    python3 -m pip install --user --break-system-packages markdown \
        || python3 -m pip install --user markdown
fi

echo "done. Sparkle tools at $BIN"
