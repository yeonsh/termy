# termy auto-update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship in-app auto-updates via Sparkle 2.x with a GitHub-Releases-hosted DMG and a Cloudflare-Pages-hosted appcast at `https://termy.nugo.cc/appcast.xml`.

**Architecture:** Three cooperating pieces — (1) a thin `Updater.swift` wrapper around `SPUStandardUpdaterController` wired into `AppDelegate`, (2) `dist.sh` extensions that EdDSA-sign the DMG and regenerate the appcast, (3) a new `publish.sh` that uploads the DMG to GitHub Releases and pushes the appcast to the static-site repo.

**Tech Stack:** Sparkle 2.x (via SPM), xcodegen, bash, Python 3 (stdlib + `markdown` pip module), `gh` CLI, Cloudflare Pages.

---

## Spec reference

Design doc: `docs/superpowers/specs/2026-04-22-auto-update-design.md` (commit d18deb9).

## Prerequisites (operator setup — not automated by this plan)

These must be done **once**, before Task 9+ can actually publish. Tasks 1–8 can be implemented without any of these. A standalone runbook (Task 12) documents them.

1. Create GitHub repo for `termy` source, push existing `main` branch.
2. Create a second GitHub repo `termy-updates` (public), clone sibling to the termy checkout (e.g. `~/proj/termy-updates`).
3. Connect `termy-updates` to Cloudflare Pages (build command `none`, output dir `/`), bind `termy.nugo.cc` as a custom domain, verify TLS with `curl -I https://termy.nugo.cc/`.
4. Generate the EdDSA keypair (Task 2 covers this), back up the private key to 1Password, paste the public key into `project.yml`.
5. `gh auth login` so `publish.sh` can create releases.

## File structure

### Created
- `scripts/setup-sparkle.sh` — one-shot installer for Sparkle's CLI tools + Python `markdown` module (Task 1)
- `scripts/bump-version.sh` — atomically bump four version fields in `project.yml` (Task 7)
- `scripts/render-release-notes.py` — extract a CHANGELOG section and render to HTML for Sparkle's `<description>` (Task 8)
- `scripts/publish.sh` — `gh release create` + push appcast to Pages repo (Task 10)
- `apps/termy/Sources/Updater.swift` — 30-line Sparkle wrapper (Task 4)
- `CHANGELOG.md` — versioned release notes, consumed by both dist.sh and publish.sh (Task 6)
- `docs/auto-update.md` — one-time setup + release runbook (Task 12)

### Modified
- `project.yml` — add Sparkle SPM package + target dep + five Sparkle Info.plist keys (Task 3)
- `apps/termy/Sources/AppDelegate.swift` — instantiate `Updater.shared` + add menu item (Task 5)
- `scripts/dist.sh` — insert sparkle-sign + generate_appcast block after notarize/staple (Task 9)
- `.env.example` — add `GITHUB_REPO`, `PAGES_REPO_PATH` (Task 11)
- `.gitignore` — add `scripts/vendor/` (Task 1)

### Notes on gitignored files
- `apps/termy/Info.plist` is **generated** by xcodegen from `project.yml`. Do not edit it directly — edits are lost on the next `xcodegen generate`. Info.plist additions in the spec are implemented as edits to `project.yml.targets.termy.info.properties`.
- `termy.xcodeproj/` is likewise regenerated. `bump-version.sh` does not stage it.

---

## Task 1: Sparkle tooling installer + gitignore

**Files:**
- Create: `scripts/setup-sparkle.sh`
- Modify: `.gitignore` (add one line)

**Context:** Sparkle ships a tarball containing `generate_keys`, `sign_update`, and `generate_appcast`. We pin a specific version (2.6.4) and verify SHA-256 so a compromised mirror can't inject a malicious tool. Python `markdown` is needed by `render-release-notes.py` in Task 8.

- [ ] **Step 1: Create `scripts/setup-sparkle.sh`**

```bash
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
SPARKLE_SHA256="REPLACE_WITH_SHA_FROM_FIRST_FAILED_RUN"

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
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/setup-sparkle.sh
```

- [ ] **Step 3: Add `scripts/vendor/` to `.gitignore`**

Append at the bottom of `.gitignore`:

```
# Sparkle CLI tools — installed by scripts/setup-sparkle.sh, per-developer.
scripts/vendor/
```

- [ ] **Step 4: Run the installer — expected to fail with SHA mismatch on first run**

```bash
scripts/setup-sparkle.sh
```

Because `SPARKLE_SHA256` is the placeholder string, this first run **must**
fail with output like:

```
setup-sparkle.sh: SHA-256 mismatch
  expected: REPLACE_WITH_SHA_FROM_FIRST_FAILED_RUN
  actual:   <actual-64-hex-chars>
```

Copy the `actual:` value. Edit `scripts/setup-sparkle.sh` and replace
`REPLACE_WITH_SHA_FROM_FIRST_FAILED_RUN` with that 64-hex-char value.

- [ ] **Step 5: Re-run the installer**

```bash
scripts/setup-sparkle.sh
```

Expected final output: `done. Sparkle tools at .../scripts/vendor/sparkle/bin`.

Verify the tools exist and run:

```bash
scripts/vendor/sparkle/bin/sign_update --help 2>&1 | head -3
scripts/vendor/sparkle/bin/generate_keys --help 2>&1 | head -3
scripts/vendor/sparkle/bin/generate_appcast --help 2>&1 | head -3
```

Each should print a usage/help blurb.

- [ ] **Step 6: Verify `scripts/vendor/` is ignored**

```bash
git status
```

Expected: `scripts/vendor/` should NOT appear. `.gitignore` and `scripts/setup-sparkle.sh` are the only pending changes.

- [ ] **Step 7: Commit**

The commit includes the `SPARKLE_SHA256` you pasted in Step 4 so subsequent developers verify against the same hash:

```bash
git add scripts/setup-sparkle.sh .gitignore
git commit -m "scripts: add Sparkle CLI installer + ignore vendor dir"
```

---

## Task 2: Generate the EdDSA keypair

**Files:** none committed in this task. The public key is recorded in the task's commit-message-style note at the bottom so subsequent tasks can reference it.

**Context:** Sparkle verifies every downloaded update against an EdDSA public key baked into the app. The private key must be generated once and backed up before anything that references it can ship.

This task is operator-manual; no code changes. It produces a public key string (40 base64 chars) that Task 3 pastes into `project.yml`.

- [ ] **Step 1: Generate the keypair**

```bash
scripts/vendor/sparkle/bin/generate_keys --account termy
```

Expected output (public key will differ — copy yours):

```
A key has been generated and saved in your keychain.
The public key (SUPublicEDKey value for your Info.plist) is:

AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExampleEx
```

**Copy the public key** — you'll paste it into `project.yml` in Task 3.

- [ ] **Step 2: Export the private key for backup**

```bash
scripts/vendor/sparkle/bin/generate_keys --account termy -p
```

This prints the private key. **Do not paste it into any file, commit, or transcript.** Copy it directly into 1Password.

- [ ] **Step 3: Store the private key in 1Password**

Create a 1Password item:
- Title: `termy Sparkle signing key`
- Password field: paste the private key from Step 2
- Notes: `Restore via: echo "<this value>" | scripts/vendor/sparkle/bin/generate_keys --account termy --import-key`

Verify the item is synced before continuing. **Losing this key bricks the update channel for every existing install forever.**

- [ ] **Step 4: Record the public key for Task 3**

Save the public key string (from Step 1) in a scratch note — you will paste it into `project.yml` as the `SUPublicEDKey` value in Task 3.

- [ ] **Step 5: (No commit — this task produces no file changes.)**

---

## Task 3: Add Sparkle dependency and Info.plist keys in project.yml

**Files:**
- Modify: `project.yml`

**Context:** `project.yml` is the source of truth for both the Xcode project and the generated `Info.plist`. Adding the SPM package here pulls Sparkle into the build; adding keys under `targets.termy.info.properties` causes xcodegen to emit them into the built app's Info.plist.

- [ ] **Step 1: Add the Sparkle SPM package under `packages:`**

Edit `project.yml`. Find the existing `packages:` block:

```yaml
packages:
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    branch: main
```

Replace with:

```yaml
packages:
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    branch: main
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

- [ ] **Step 2: Add Sparkle as a dependency of the `termy` target**

In the same file, find `targets.termy.dependencies:`. It currently reads:

```yaml
    dependencies:
      - package: SwiftTerm
        product: SwiftTerm
      - target: termy-hook
        copy:
          destination: resources
```

Replace with:

```yaml
    dependencies:
      - package: SwiftTerm
        product: SwiftTerm
      - package: Sparkle
      - target: termy-hook
        copy:
          destination: resources
```

- [ ] **Step 3: Add Sparkle Info.plist keys**

In the same file, find `targets.termy.info.properties:`. It currently ends with `NSSupportsSuddenTermination: NO`. Append these five keys **inside the same `properties:` block**:

```yaml
        SUFeedURL: "https://termy.nugo.cc/appcast.xml"
        SUPublicEDKey: "PASTE_PUBLIC_KEY_FROM_TASK_2_HERE"
        SUEnableAutomaticChecks: true
        SUScheduledCheckInterval: 86400
        SUAllowsAutomaticUpdates: false
```

Replace `PASTE_PUBLIC_KEY_FROM_TASK_2_HERE` with the public key string saved in Task 2 Step 4. Double-check there is no leading/trailing whitespace.

The final properties block should look like:

```yaml
    info:
      path: apps/termy/Info.plist
      properties:
        CFBundleName: termy
        CFBundleDisplayName: termy
        CFBundleIdentifier: app.termy.macos
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSMinimumSystemVersion: "14.0"
        NSHumanReadableCopyright: "© 2026 termy"
        NSHighResolutionCapable: YES
        NSPrincipalClass: NSApplication
        LSUIElement: NO
        NSSupportsAutomaticTermination: NO
        NSSupportsSuddenTermination: NO
        SUFeedURL: "https://termy.nugo.cc/appcast.xml"
        SUPublicEDKey: "<your public key>"
        SUEnableAutomaticChecks: true
        SUScheduledCheckInterval: 86400
        SUAllowsAutomaticUpdates: false
```

- [ ] **Step 4: Regenerate the Xcode project**

```bash
xcodegen generate --quiet
```

Expected: no output (exit 0). If xcodegen errors on YAML syntax, revert and fix the indentation.

- [ ] **Step 5: Verify the generated Info.plist contains the keys**

```bash
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' apps/termy/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' apps/termy/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' apps/termy/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' apps/termy/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' apps/termy/Info.plist
```

Expected:
```
https://termy.nugo.cc/appcast.xml
<your public key string>
true
86400
false
```

- [ ] **Step 6: Verify the SPM package resolved**

Build just enough to force SPM resolution:

```bash
xcodebuild -project termy.xcodeproj -scheme termy -configuration Debug -destination 'generic/platform=macOS' -showBuildSettings >/dev/null
```

Then check:

```bash
ls ~/Library/Developer/Xcode/DerivedData | head
```

If you see `termy-*/SourcePackages/checkouts/Sparkle`, SPM pulled it. If resolution fails, try `xcodebuild -resolvePackageDependencies -project termy.xcodeproj`.

- [ ] **Step 7: Commit**

```bash
git add project.yml
git commit -m "project: add Sparkle 2.6 dependency + update config keys"
```

---

## Task 4: Implement `Updater.swift`

**Files:**
- Create: `apps/termy/Sources/Updater.swift`

**Context:** A 30-line wrapper that owns `SPUStandardUpdaterController`. `NSObject` inheritance is required so `#selector` resolves through the Objective-C runtime for the menu target/action in Task 5.

- [ ] **Step 1: Create `apps/termy/Sources/Updater.swift`**

```swift
// Updater.swift
//
// Thin wrapper around Sparkle's SPUStandardUpdaterController. Instantiated
// once from AppDelegate.applicationDidFinishLaunching; takes over the
// "Check for Updates…" menu item target. No delegate methods — Sparkle's
// defaults cover prompt UX, signature verification, and error dialogs.

import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    override private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
```

- [ ] **Step 2: Regenerate the project so the new file is tracked**

```bash
xcodegen generate --quiet
```

xcodegen's `sources: - path: apps/termy/Sources` glob picks up `Updater.swift` automatically.

- [ ] **Step 3: Build to confirm Sparkle imports**

```bash
xcodebuild -project termy.xcodeproj -scheme termy -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

If you see `No such module 'Sparkle'`, SPM resolution didn't complete — run `xcodebuild -resolvePackageDependencies -project termy.xcodeproj` and retry.

- [ ] **Step 4: Commit**

```bash
git add apps/termy/Sources/Updater.swift
git commit -m "updater: add Sparkle-backed auto-update controller"
```

---

## Task 5: Wire `Updater` into `AppDelegate`

**Files:**
- Modify: `apps/termy/Sources/AppDelegate.swift` (two insertions)

**Context:** Two changes — one to start the background updater on launch, one to add the user-visible menu item.

- [ ] **Step 1: Start the updater in `applicationDidFinishLaunching`**

Open `apps/termy/Sources/AppDelegate.swift`. Find the end of `applicationDidFinishLaunching(_:)` — currently lines 72–75 look like:

```swift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FullDiskAccess.promptIfNeeded()
            HookInstaller.promptIfNeeded()
        }
    }
```

Change to (add one line + one comment):

```swift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FullDiskAccess.promptIfNeeded()
            HookInstaller.promptIfNeeded()
        }

        // Instantiating SPUStandardUpdaterController on first access starts
        // background update checks against SUFeedURL (see Info.plist).
        _ = Updater.shared
    }
```

- [ ] **Step 2: Add the "Check for Updates…" menu item**

In the same file, find `makeAppMenu()` (starts around line 257). The first two real menu lines are the About item (lines 260–264) followed by a separator (line 265):

```swift
        menu.addItem(
            withTitle: "About termy",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
```

Insert the update item **between** them. Replace that block with:

```swift
        menu.addItem(
            withTitle: "About termy",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let update = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(Updater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = Updater.shared
        menu.addItem(.separator())
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project termy.xcodeproj -scheme termy -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch the built app and verify the menu**

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/"termy-*/Build/Products/Debug/termy.app
```

- Click the `termy` menu in the menu bar.
- Verify `Check for Updates…` appears directly under `About termy`, above the separator.
- Click it. You should see Sparkle's "Checking for updates…" HUD, followed by an error ("Could not connect to …"). This is expected — `termy.nugo.cc` is not yet serving an appcast (infrastructure is set up in Task 12), and the local Debug build's version does not correspond to a published release. The important verification is that the menu item is wired and Sparkle loads.

Quit the app when done.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/AppDelegate.swift
git commit -m "appdelegate: wire Updater.shared into launch + app menu"
```

---

## Task 6: Create CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

**Context:** Both `dist.sh` (via `render-release-notes.py`) and `publish.sh` (via `gh release create --notes-file`) consume this file. A section heading must match the marketing version being released, for `render-release-notes.py` to extract it.

- [ ] **Step 1: Create `CHANGELOG.md`**

```markdown
# Changelog

All notable changes to termy. Each section heading's version must match the
`CFBundleShortVersionString` at release time — `scripts/render-release-notes.py`
extracts the matching section into the Sparkle appcast `<description>`.

## 0.1.0 — 2026-04-22

Initial release.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG with 0.1.0 entry"
```

---

## Task 7: Implement `scripts/bump-version.sh`

**Files:**
- Create: `scripts/bump-version.sh`

**Context:** Four version fields in `project.yml` must stay in lockstep. `CFBundleVersion` is Sparkle's ordering key — strictly +1 per release.

- [ ] **Step 1: Create the script**

```bash
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
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/bump-version.sh
```

- [ ] **Step 3: Smoke-test by bumping and reverting**

```bash
scripts/bump-version.sh 0.1.1
git diff --staged project.yml
```

Expected diff — all four fields changed from `"0.1.0"`/`"1"` to `"0.1.1"`/`"2"`:

```
-        CFBundleShortVersionString: "0.1.0"
-        CFBundleVersion: "1"
+        CFBundleShortVersionString: "0.1.1"
+        CFBundleVersion: "2"
...
-        MARKETING_VERSION: "0.1.0"
-        CURRENT_PROJECT_VERSION: "1"
+        MARKETING_VERSION: "0.1.1"
+        CURRENT_PROJECT_VERSION: "2"
```

- [ ] **Step 4: Verify downgrade protection**

```bash
scripts/bump-version.sh 0.0.9
```

Expected: exits non-zero with `bump-version.sh: 0.0.9 is lower than current 0.1.1`.

- [ ] **Step 5: Verify same-version rejection**

```bash
scripts/bump-version.sh 0.1.1
```

Expected: `bump-version.sh: 0.1.1 is already the current version`.

- [ ] **Step 6: Revert the smoke-test bump**

```bash
git restore --staged project.yml
git restore project.yml
xcodegen generate --quiet
```

Verify:

```bash
grep -E 'CFBundleShortVersionString|CFBundleVersion:|MARKETING_VERSION|CURRENT_PROJECT_VERSION' project.yml
```

Expected: all four back to `0.1.0` / `1`.

- [ ] **Step 7: Commit the script itself**

```bash
git add scripts/bump-version.sh
git commit -m "scripts: add bump-version.sh for release-time version rewrites"
```

---

## Task 8: Implement `scripts/render-release-notes.py`

**Files:**
- Create: `scripts/render-release-notes.py`

**Context:** Extracts the CHANGELOG section whose `## N.N.N` heading matches `--version`, converts markdown to HTML, writes to `--output`. Called from `dist.sh`. Soft-failure contract: `dist.sh` tolerates non-zero exit by continuing without a `<description>`.

- [ ] **Step 1: Create the script**

```python
#!/usr/bin/env python3
"""Extract a CHANGELOG.md section and render it to HTML for Sparkle.

CHANGELOG sections are expected to start with `## <version>` (anything after
the version on the heading line is ignored — e.g. "## 0.2.0 — 2026-04-22").
The section ends at the next `## ` heading or end of file.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def extract_section(text: str, version: str) -> str | None:
    # Match `## <version>` at start of line, optionally followed by anything.
    start_re = re.compile(
        rf"^##\s+{re.escape(version)}(\s|$)", re.MULTILINE
    )
    next_heading_re = re.compile(r"^##\s+", re.MULTILINE)

    m = start_re.search(text)
    if not m:
        return None

    body_start = m.end()
    next_m = next_heading_re.search(text, body_start)
    body_end = next_m.start() if next_m else len(text)

    return text[body_start:body_end].strip()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True, help="semver to extract (e.g. 0.2.0)")
    p.add_argument("--input", required=True, type=Path, help="CHANGELOG.md path")
    p.add_argument("--output", required=True, type=Path, help="HTML output path")
    args = p.parse_args()

    try:
        import markdown
    except ImportError:
        print(
            "render-release-notes.py: `markdown` module not installed. "
            "Run scripts/setup-sparkle.sh.",
            file=sys.stderr,
        )
        return 1

    text = args.input.read_text(encoding="utf-8")
    section = extract_section(text, args.version)
    if section is None:
        print(
            f"render-release-notes.py: no `## {args.version}` section in {args.input}",
            file=sys.stderr,
        )
        return 1

    html = markdown.markdown(section, extensions=["fenced_code"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(html + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/render-release-notes.py
```

- [ ] **Step 3: Smoke-test with the existing 0.1.0 section**

```bash
scripts/render-release-notes.py --version 0.1.0 --input CHANGELOG.md --output /tmp/relnotes.html
cat /tmp/relnotes.html
```

Expected output (wrapped in `<p>` because "Initial release." is a paragraph):

```html
<p>Initial release.</p>
```

Exit code 0.

- [ ] **Step 4: Verify not-found returns non-zero**

```bash
scripts/render-release-notes.py --version 99.99.99 --input CHANGELOG.md --output /tmp/noop.html
echo "exit=$?"
```

Expected: stderr message `no '## 99.99.99' section in CHANGELOG.md`, exit code 1. `/tmp/noop.html` should NOT exist (early return before write).

- [ ] **Step 5: Clean up smoke-test artifacts**

```bash
rm -f /tmp/relnotes.html /tmp/noop.html
```

- [ ] **Step 6: Commit**

```bash
git add scripts/render-release-notes.py
git commit -m "scripts: add render-release-notes.py for Sparkle <description>"
```

---

## Task 9: Extend `scripts/dist.sh` with sparkle signing + appcast generation

**Files:**
- Modify: `scripts/dist.sh` (insert ~25 lines near the end)

**Context:** After notarize+staple finishes, sign the DMG with EdDSA and regenerate `appcast.xml`. `--skip-notarize` already early-exits at line 121, so this block is unreachable when notarization is skipped.

- [ ] **Step 1: Insert the sparkle block**

Open `scripts/dist.sh`. Find the last two lines:

```bash
echo "done: $DMG  (v${VERSION} build ${BUILD})"
```

(That's line 137.)

Immediately **before** that `echo "done:"` line, insert:

```bash
echo "==> sparkle sign + appcast"
SPARKLE_BIN="$ROOT/scripts/vendor/sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "dist.sh: Sparkle tools missing at $SPARKLE_BIN" >&2
    echo "         run scripts/setup-sparkle.sh first" >&2
    exit 1
fi

APPCAST_STAGING="$DIST/appcast-staging"
rm -rf "$APPCAST_STAGING"
mkdir -p "$APPCAST_STAGING"
cp "$DMG" "$APPCAST_STAGING/"

# Render release-notes HTML next to the DMG (same stem). generate_appcast
# uses it as the <description> for this release. Soft-fail: a missing
# description is not a release blocker.
CHANGELOG_MD="$ROOT/CHANGELOG.md"
if [[ -f "$CHANGELOG_MD" ]]; then
    python3 "$ROOT/scripts/render-release-notes.py" \
        --version "$VERSION" \
        --input "$CHANGELOG_MD" \
        --output "$APPCAST_STAGING/termy ${VERSION}.html" \
        || echo "dist.sh: release-notes render failed; continuing without description"
fi

: "${GITHUB_REPO:?GITHUB_REPO not set — copy .env.example to .env and fill it in}"

"$SPARKLE_BIN/generate_appcast" \
    --account termy \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/" \
    --link "https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}" \
    "$APPCAST_STAGING"

mv "$APPCAST_STAGING/appcast.xml" "$DIST/appcast.xml"
echo "==> appcast ready at $DIST/appcast.xml"
```

The final line order at the bottom of `dist.sh` should now be:

```bash
echo "==> gatekeeper check"
spctl --assess --type execute --verbose=4 "$APP" || true
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || true

echo "==> sparkle sign + appcast"
# … (block from above) …
echo "==> appcast ready at $DIST/appcast.xml"

echo "done: $DMG  (v${VERSION} build ${BUILD})"
```

- [ ] **Step 2: Shellcheck the script**

```bash
shellcheck scripts/dist.sh 2>&1 | head -30 || true
```

Expected: no new warnings introduced. Pre-existing warnings (if any) can stay.

- [ ] **Step 3: Sanity-check syntax without running full pipeline**

```bash
bash -n scripts/dist.sh
echo "exit=$?"
```

Expected exit 0.

- [ ] **Step 4: Dry-run with `--skip-notarize` to verify the block is unreachable**

Temporarily skip full pipeline; just verify the existing short-circuit still exits before the new block:

```bash
grep -n "skipping notarization" scripts/dist.sh
```

Expected: one line; the skipped-notarize branch `exit 0`s **before** reaching the sparkle block. Confirm visually by `grep -n "sparkle sign" scripts/dist.sh` and seeing it comes after `exit 0` on the skipped-notarize path.

A full `scripts/dist.sh` run is deferred until the operator has set `GITHUB_REPO` in `.env` (Task 11) and generated a DMG against real notarization. This task ships the code change; end-to-end execution happens in Task 13.

- [ ] **Step 5: Commit**

```bash
git add scripts/dist.sh
git commit -m "dist.sh: sign DMG with Sparkle + regenerate appcast.xml"
```

---

## Task 10: Implement `scripts/publish.sh`

**Files:**
- Create: `scripts/publish.sh`

**Context:** Run after `dist.sh`. Creates a GitHub release with the DMG as an asset, pushes the regenerated appcast to the Pages repo. Ordering: GitHub release first, appcast second (so clients never get an appcast pointing at a 404 DMG URL).

- [ ] **Step 1: Create the script**

```bash
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
NOTES_FILE="${RELEASE_NOTES_FILE:-$ROOT/CHANGELOG.md}"

echo "==> gh auth check"
gh auth status >/dev/null

echo "==> create GitHub release $TAG (DMG upload)"
gh release create "$TAG" "$DMG" \
    --repo "$GITHUB_REPO" \
    --title "termy ${VERSION}" \
    --notes-file "$NOTES_FILE"

echo "==> publish appcast to Pages repo at $PAGES"
cp "$APPCAST" "$PAGES/appcast.xml"
git -C "$PAGES" add appcast.xml
git -C "$PAGES" commit -m "termy ${VERSION}"
git -C "$PAGES" push

echo "done:"
echo "  release: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "  appcast: https://termy.nugo.cc/appcast.xml (Pages deploy ~30s)"
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/publish.sh
```

- [ ] **Step 3: Shellcheck + syntax sanity**

```bash
shellcheck scripts/publish.sh 2>&1 | head -30 || true
bash -n scripts/publish.sh
echo "exit=$?"
```

Expected: no shellcheck regressions, `bash -n` exit 0.

- [ ] **Step 4: Dry-run without artifacts to verify error path**

```bash
scripts/publish.sh
```

Expected: exits non-zero with `run scripts/dist.sh first — missing DMG or appcast.xml under .../build/dist`. This confirms the guard works without actually calling `gh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.sh
git commit -m "scripts: add publish.sh for GH release + Pages appcast push"
```

---

## Task 11: Update `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Append the new env vars**

Open `.env.example`. It currently ends with the `SIGNING_IDENTITY=...` line. Append:

```
# GitHub repo used for auto-update release hosting (owner/name).
# Consumed by scripts/dist.sh (appcast URL prefix) and scripts/publish.sh.
GITHUB_REPO=yourname/termy

# Path to the local clone of the termy-updates Pages repo. Default: ../termy-updates.
# Consumed by scripts/publish.sh.
PAGES_REPO_PATH=../termy-updates

# Optional override for GitHub release body. Defaults to CHANGELOG.md.
# RELEASE_NOTES_FILE=build/dist/release-notes.md
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "env: add GITHUB_REPO, PAGES_REPO_PATH for auto-update pipeline"
```

---

## Task 12: Create the one-time setup + release runbook

**Files:**
- Create: `docs/auto-update.md`

**Context:** The infrastructure prerequisites (GitHub repos, Cloudflare Pages, DNS, EdDSA keygen) are manual and touch external systems. This doc is the single place to look when setting up a new build machine or onboarding a collaborator.

- [ ] **Step 1: Create `docs/auto-update.md`**

````markdown
# Auto-update runbook

Design doc: [docs/superpowers/specs/2026-04-22-auto-update-design.md](./superpowers/specs/2026-04-22-auto-update-design.md).

Termy auto-updates via Sparkle. The DMG lives on GitHub Releases, the appcast
feed lives at `https://termy.nugo.cc/appcast.xml` served by Cloudflare Pages
from a separate `termy-updates` repo.

## One-time setup

### 1. Create GitHub repos

- `termy` (this repo) — push `main` to GitHub. Set `GITHUB_REPO=<owner>/termy`
  in `.env`.
- `termy-updates` — new **public** repo holding only the appcast. Clone it
  sibling to termy (e.g. `~/proj/termy-updates`). Set
  `PAGES_REPO_PATH=../termy-updates` in `.env`.

### 2. Cloudflare Pages

- Connect `termy-updates` to Cloudflare Pages.
- Build command: `none`. Output dir: `/`.
- Add `termy.nugo.cc` as a custom domain. Cloudflare handles TLS.
- CNAME `termy.nugo.cc → <project>.pages.dev` on whatever manages `nugo.cc`.

Verify:
```bash
curl -I https://termy.nugo.cc/
# expect HTTP/2 200
```

Seed the repo with a placeholder `appcast.xml` (empty channel) so the first
real release's push isn't the first ever deploy:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>termy updates</title>
    <link>https://termy.nugo.cc/appcast.xml</link>
    <description>termy release feed</description>
  </channel>
</rss>
```

### 3. Install Sparkle CLI + Python `markdown`

```bash
scripts/setup-sparkle.sh
```

Re-run this on every new build machine.

### 4. Generate the EdDSA keypair (one time, ever)

```bash
scripts/vendor/sparkle/bin/generate_keys --account termy
```

Copy the printed public key into `project.yml` under
`targets.termy.info.properties.SUPublicEDKey`.

**Export the private key and store in 1Password** before anything else:

```bash
scripts/vendor/sparkle/bin/generate_keys --account termy -p
```

Paste the value into a 1Password item titled "termy Sparkle signing key". Note
the restore command: `echo "<value>" | scripts/vendor/sparkle/bin/generate_keys --account termy --import-key`.

**Losing this key bricks update delivery to every existing install.** Verify
the 1Password item is synced before the first public release.

### 5. `gh` CLI auth

```bash
gh auth login
gh auth status
```

## Cutting a release

1. Bump version:
   ```bash
   scripts/bump-version.sh 0.2.0
   ```

2. Update `CHANGELOG.md` — add `## 0.2.0 — YYYY-MM-DD` section at the top.
   Review the staged `project.yml` diff, then commit:
   ```bash
   git diff --staged project.yml
   git commit -am "termy 0.2.0"
   git tag -a v0.2.0 -m "termy 0.2.0"
   ```

3. Build, sign, notarize, emit appcast:
   ```bash
   scripts/dist.sh
   ```
   Produces `build/dist/termy-0.2.0.dmg` and `build/dist/appcast.xml`.

4. Publish to GitHub + Cloudflare Pages:
   ```bash
   scripts/publish.sh
   ```

5. Push source commit + tag last:
   ```bash
   git push --follow-tags
   ```

The source push is deliberately last: if `dist.sh` or `publish.sh` fails
midway, rolling back is local-only.

## Rollback

Append-only — never unpublish. If 0.2.0 is broken, cut 0.2.1 via the same
flow. Users on 0.2.0 receive 0.2.1 on the next scheduled check (~24h) or
immediately on `Check for Updates…`.

## Loss-of-key recovery

If the EdDSA private key is gone (1Password item gone, no backup):

1. Generate a new keypair.
2. Ship a new DMG with the new `SUPublicEDKey`.
3. Reach existing users out-of-band (email, site banner, Twitter) with drag-
   replace instructions. Subsequent updates work normally.

This is catastrophic. Don't lose the key.
````

- [ ] **Step 2: Commit**

```bash
git add docs/auto-update.md
git commit -m "docs: add auto-update setup + release runbook"
```

---

## Task 13: Local feed smoke test (manual verification)

**Files:** none committed; verifies Tasks 1–12 end-to-end on a local feed before any production push.

**Context:** Spec Layer 1 testing — verify Sparkle's full download+verify+install+relaunch path works using a localhost feed and a signed-but-not-notarized DMG. This surfaces configuration bugs before they reach a real user.

- [ ] **Step 1: Build an unnotarized DMG**

```bash
scripts/dist.sh --skip-notarize
```

Expected: `build/dist/termy-0.1.0.dmg` exists, unnotarized. No `appcast.xml` (skipped before that block).

- [ ] **Step 2: Sign the DMG manually**

```bash
SIG="$(scripts/vendor/sparkle/bin/sign_update --account termy build/dist/termy-0.1.0.dmg)"
echo "$SIG"
```

Expected output format: `sparkle:edSignature="..." length="..."`.

- [ ] **Step 3: Hand-craft a local appcast**

`sign_update` already emits both `sparkle:edSignature="..."` and `length="..."`
as attributes, so `$SIG` contributes both — do not add a separate `length`
attribute to the enclosure or the XML will have a duplicate attribute:

```bash
cat > build/dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>termy updates (local test)</title>
    <item>
      <title>termy 9.9.9</title>
      <sparkle:version>999</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure
        url="http://localhost:8080/termy-0.1.0.dmg"
        type="application/octet-stream"
        $SIG />
    </item>
  </channel>
</rss>
EOF
```

Validate the result:

```bash
xmllint --noout build/dist/appcast.xml && echo "xml ok"
```

Expected: `xml ok`. If `xmllint` reports a duplicate `length` attribute, `$SIG`
expanded into a context where an earlier edit of this file also included
`length="..."` — remove it.

- [ ] **Step 4: Serve the feed locally**

In a separate terminal:

```bash
cd build/dist && python3 -m http.server 8080
```

Leave it running.

- [ ] **Step 5: Point a Debug build at the local feed**

```bash
defaults write app.termy.macos SUFeedURL http://localhost:8080/appcast.xml
```

- [ ] **Step 6: Launch the Debug build and trigger an update check**

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/"termy-*/Build/Products/Debug/termy.app
```

In the app: `termy → Check for Updates…`.

Expected: Sparkle's "Update Available — termy 9.9.9" dialog. Click "Install
Update". Observe the download progress, signature verification, app relaunch
as version 9.9.9.

If the update fails: check Console.app, filter for `Sparkle`, and inspect
error messages. Common issues:
- Signature mismatch → `sign_update` was run after the DMG was modified.
- "Update is for older version" → `sparkle:version` (build number) must be
  strictly greater than the running app's `CFBundleVersion`.

- [ ] **Step 7: Clean up**

```bash
defaults delete app.termy.macos SUFeedURL
pkill -f "python3 -m http.server 8080" || true
```

Kill the `python3 -m http.server` in the other terminal.

- [ ] **Step 8: Verify cleanup**

```bash
defaults read app.termy.macos SUFeedURL 2>&1
```

Expected: `does not exist` (so the prod Info.plist URL is used on next launch).

- [ ] **Step 9: (No commit — this task produces no file changes. Integration success = plan complete.)**

---

## Plan complete

After Task 13 passes, the pipeline is ready for a real release cut. The first
real release (decision point for the operator — whether that's 0.1.1 or 0.2.0)
happens outside this plan's scope, following the runbook in
`docs/auto-update.md`.
