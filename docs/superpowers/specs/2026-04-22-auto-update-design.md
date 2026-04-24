# termy auto-update — design

**Date:** 2026-04-22
**Author:** @ysh (via brainstorming session)
**Status:** approved, ready for implementation plan

## Goal

Ship a background auto-update mechanism so termy users on any previously-released
version are offered the latest release without re-downloading a DMG by hand.
Optimise for: minimal in-app code, canonical macOS UX, no new always-on
infrastructure.

## Decisions locked during brainstorming

| # | Decision | Choice |
|---|---|---|
| 1 | Hosting model | Sparkle + GitHub Releases (DMG) + own-domain appcast |
| 2 | Check visibility | Background + Sparkle's standard "update available" dialog |
| 3 | First-launch prompt | None. Auto-checks enabled by default. |
| 4 | UI surface | Single `Check for Updates…` menu item. No preferences pane. |
| 5 | EdDSA key storage | Login keychain, backed up to 1Password |
| 6 | Appcast host | `https://termy.nugo.cc/appcast.xml` (Cloudflare Pages) |
| 7 | Integration style | Sparkle 2.x via SPM, vanilla `SPUStandardUpdaterController` |
| 8 | Beta channel | Not in v1. Single stable feed. |
| 9 | Delta updates | Not in v1. Full-DMG downloads only. |

## Architecture

Three cooperating pieces:

1. **In-app updater** (`apps/termy/Sources/Updater.swift`, new) — thin wrapper
   around `SPUStandardUpdaterController`. Exposes a single `@objc` method wired
   to the `Check for Updates…` menu item.
2. **Release signer** (extensions to `scripts/dist.sh`) — after notarize + staple,
   runs Sparkle's `sign_update` to produce an EdDSA signature, then
   `generate_appcast` to emit a refreshed `appcast.xml`.
3. **Publisher** (`scripts/publish.sh`, new) — uploads the DMG as a GitHub
   release asset, pushes the regenerated `appcast.xml` to the `termy-updates`
   Pages repo. Kept separate from `dist.sh` so `dist.sh --skip-notarize` retains
   offline-only local builds.

### Release-time data flow

```
scripts/dist.sh → build/dist/termy-<v>.dmg         (signed, notarized, stapled)
scripts/dist.sh → build/dist/appcast.xml           (EdDSA-signed entry added)
scripts/publish.sh → gh release create vX.Y.Z      (DMG uploaded as asset)
scripts/publish.sh → git push in termy-updates     (Pages auto-deploys)
                     → https://termy.nugo.cc/appcast.xml
```

### Client-side update flow

```
Sparkle (in-app) → GET https://termy.nugo.cc/appcast.xml
                 → compare vs CFBundleShortVersionString
                 → if newer:
                     download DMG from github.com/<user>/termy/releases/...
                     verify EdDSA sig vs SUPublicEDKey
                     verify Apple codesign + stapled notarization (macOS)
                     prompt user (standard Sparkle dialog)
                     on accept: swap .app, relaunch
```

## Components

### `apps/termy/Sources/Updater.swift` (new)

```swift
import Sparkle
import AppKit

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

`Updater` inherits `NSObject` so `#selector(Updater.checkForUpdates(_:))` in
the menu wiring resolves through the Objective-C runtime — required for
`NSMenuItem` target/action. (Matches how `AppDelegate` is declared in the
existing codebase.)

No delegate methods in v1 — Sparkle's defaults handle prompt UX, error dialogs,
and signature verification.

### `AppDelegate`

Two changes:

- `applicationDidFinishLaunching`: add `_ = Updater.shared` at the end.
  Instantiating `SPUStandardUpdaterController(startingUpdater: true, …)` is all
  that's needed to begin the background check schedule.
- `makeAppMenu()` (in `AppDelegate.swift`): insert a menu item immediately after
  the `About termy` item (currently line 261–264), before the first separator
  (line 265):
  ```swift
  let update = menu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(Updater.checkForUpdates(_:)),
      keyEquivalent: ""
  )
  update.target = Updater.shared
  ```

### `apps/termy/Info.plist` (five new keys)

```xml
<key>SUFeedURL</key>
<string>https://termy.nugo.cc/appcast.xml</string>
<key>SUPublicEDKey</key>
<string><!-- pasted in after first key generation, see §Key management --></string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
<key>SUAllowsAutomaticUpdates</key>
<false/>
```

- `SUEnableAutomaticChecks=YES` with no `SUPromptUserOnFirstLaunch` key ⇒
  auto-checks enabled without a first-run dialog (decision #3).
- `SUAllowsAutomaticUpdates=NO` ⇒ Sparkle always prompts before installing.
  Since there is no preferences pane for the user to toggle this, defaulting to
  "always prompt" is the safe choice.
- `SUPublicEDKey` stays empty in the committed plist until the EdDSA keypair is
  generated (one-time setup). Once set, it is constant forever — rotating it
  bricks update flow for every existing install (see Key rotation).

### `project.yml`

```yaml
packages:
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    branch: main
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

And under `targets.termy.dependencies`:
```yaml
  - package: Sparkle
```

No entitlement changes. Sparkle 2 uses an internal XPC helper for the installer
that works with unsandboxed apps (termy has `com.apple.security.app-sandbox:
false`) without extra entitlements.

### `scripts/vendor/sparkle/` (gitignored)

Extracted from the pinned Sparkle 2.x release tarball. Contains
`bin/generate_keys`, `bin/sign_update`, `bin/generate_appcast`. Must be set up
once per developer machine (see "One-time setup" below). `.gitignore` adds
`scripts/vendor/`.

### `scripts/dist.sh` additions

After the existing gatekeeper check block, before the final `echo "done:"`:

```bash
echo "==> sparkle sign"
SPARKLE_BIN="$ROOT/scripts/vendor/sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
    echo "dist.sh: Sparkle tools missing at $SPARKLE_BIN" >&2
    echo "         run scripts/setup-sparkle.sh first" >&2
    exit 1
fi

APPCAST_STAGING="$DIST/appcast-staging"
rm -rf "$APPCAST_STAGING"
mkdir -p "$APPCAST_STAGING"
cp "$DMG" "$APPCAST_STAGING/"

# Render release-notes HTML next to the DMG (same stem).
# generate_appcast picks up "<stem>.html" as the <description> for that release.
# We extract the latest section from CHANGELOG.md and run it through
# `python3 -m markdown` (stdlib-only on macOS system Python is missing the
# markdown module; spec installs it via `python3 -m pip install --user
# markdown` in setup-sparkle.sh). Bail soft on failure — a missing
# description is not a release blocker.
CHANGELOG_MD="$ROOT/CHANGELOG.md"
if [[ -f "$CHANGELOG_MD" ]]; then
    python3 "$ROOT/scripts/render-release-notes.py" \
        --version "$VERSION" \
        --input "$CHANGELOG_MD" \
        --output "$APPCAST_STAGING/termy ${VERSION}.html" \
        || echo "dist.sh: release-notes render failed; continuing without description"
fi

"$SPARKLE_BIN/generate_appcast" \
    --account termy \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/" \
    --link "https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}" \
    "$APPCAST_STAGING"

mv "$APPCAST_STAGING/appcast.xml" "$DIST/appcast.xml"
echo "==> sparkle appcast ready: $DIST/appcast.xml"
```

`--skip-notarize` still short-circuits before this block. The script prints a
reminder: "skipped appcast; use full pipeline to publish."

### `scripts/publish.sh` (new)

```bash
#!/usr/bin/env bash
# Publish a finished DMG + appcast to GitHub Releases and termy.nugo.cc.
#
# Preconditions:
#   - scripts/dist.sh completed successfully (no --skip-notarize)
#   - build/dist/termy-<v>.dmg and build/dist/appcast.xml exist
#   - gh CLI authenticated (gh auth status)
#   - termy-updates Pages repo cloned at $PAGES_REPO_PATH
#
# Usage:
#   scripts/publish.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[[ -f "$ROOT/.env" ]] && { set -a; . "$ROOT/.env"; set +a; }

: "${GITHUB_REPO:?GITHUB_REPO not set — see .env.example}"
PAGES="${PAGES_REPO_PATH:-$ROOT/../termy-updates}"
[[ -d "$PAGES/.git" ]] || { echo "no Pages repo at $PAGES" >&2; exit 1; }

DIST="$ROOT/build/dist"
DMG="$(ls "$DIST"/termy-*.dmg 2>/dev/null | head -n1)"
APPCAST="$DIST/appcast.xml"
[[ -f "$DMG" && -f "$APPCAST" ]] || { echo "run dist.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DIST/export/termy.app/Contents/Info.plist")"
TAG="v${VERSION}"

echo "==> create GitHub release $TAG (DMG upload)"
gh release create "$TAG" "$DMG" \
    --repo "$GITHUB_REPO" \
    --title "termy ${VERSION}" \
    --notes-file "${RELEASE_NOTES_FILE:-CHANGELOG.md}"

echo "==> publish appcast to Pages repo ($PAGES)"
cp "$APPCAST" "$PAGES/appcast.xml"
git -C "$PAGES" add appcast.xml
git -C "$PAGES" commit -m "termy ${VERSION}"
git -C "$PAGES" push

echo "done: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "      appcast at https://termy.nugo.cc/appcast.xml (Pages deploy ~30s)"
```

Ordering is deliberate: GitHub release is created (DMG uploaded) **before** the
appcast is pushed. Otherwise clients would 404 on the DMG URL for the ~30s
between `gh release create` and GitHub processing the asset.

Re-running `publish.sh` for an existing tag fails loudly on `gh release create`
(409 Conflict). That's correct: releases are not silently overwritten. To
re-cut, bump the version.

### `scripts/bump-version.sh` (new)

Version currently lives in four fields of `project.yml`:

```yaml
settings.base.MARKETING_VERSION:            "0.1.0"   # semver shown to users
settings.base.CURRENT_PROJECT_VERSION:      "1"       # build number
targets.termy.info.properties.CFBundleShortVersionString: "0.1.0"
targets.termy.info.properties.CFBundleVersion:            "1"
```

Keeping these four in sync manually is a footgun — Sparkle **compares
`CFBundleVersion` as the ordering key**, so a skipped increment means clients
won't see the update. `bump-version.sh` collapses the four-field edit into one
command.

Contract:

```bash
scripts/bump-version.sh <new-semver>
```

- Parses current `CFBundleVersion` (e.g. `7`) from `project.yml` and
  increments by 1.
- Rewrites all four fields in `project.yml` to the new values (`yq` if
  available, else deterministic `sed` with anchored patterns).
- Runs `xcodegen generate --quiet` so `termy.xcodeproj` reflects the change.
- Stages `project.yml` and `termy.xcodeproj/` but does NOT commit — operator
  reviews the diff, updates `CHANGELOG.md`, then commits. Keeping commit
  authorship manual means the release commit message can say something useful
  ("termy 0.2.0 — split-pane filter shortcuts, hook daemon reliability
  fixes").
- Fails loudly if `new-semver` is ≤ the current `MARKETING_VERSION` (avoids
  accidental downgrade). Build-number increment is not user-controlled — it
  always goes +1.

Expected runtime: <1s. Roughly 40 lines of bash.

### `scripts/render-release-notes.py` (new)

Small helper script invoked by `dist.sh`. Reads `CHANGELOG.md`, extracts the
section whose heading matches the current `--version` (e.g. `## 0.2.0 — …`),
renders it to HTML via the `markdown` Python package, writes to `--output`.
Exits non-zero if the section is not found or the module is missing — callers
in `dist.sh` tolerate this with a warning. Roughly 40 lines; full contents
belong in the implementation plan, not this spec.

### Two different release-notes artifacts (don't conflate)

Sparkle and GitHub consume different formats:

| Consumer | Format | Source | Entry point |
|---|---|---|---|
| Sparkle appcast `<description>` | HTML | `CHANGELOG.md` → rendered by `render-release-notes.py` | `dist.sh` (see above) |
| GitHub release body | Markdown | `CHANGELOG.md` directly | `publish.sh` via `gh release create --notes-file` |

Both flow from the same `CHANGELOG.md` source, but the rendering paths are
separate. This is intentional — forcing a single format would create a
conversion step on one side or the other.

### `.env.example` additions

```
# Existing
TEAM_ID=...
SIGNING_IDENTITY=...

# New for auto-update
GITHUB_REPO=yourname/termy
PAGES_REPO_PATH=../termy-updates
# Optional GH release body override (defaults to CHANGELOG.md):
# RELEASE_NOTES_FILE=build/dist/release-notes.md
```

## Release workflow

End-to-end operator flow for cutting `0.2.0` as an example:

```bash
# 1. Bump version (4 fields in project.yml, +1 build number, regenerates .xcodeproj)
scripts/bump-version.sh 0.2.0

# 2. Update changelog, review, commit, tag
$EDITOR CHANGELOG.md           # add "## 0.2.0 — 2026-04-22" section
git diff                       # sanity check all four version fields moved
git commit -am "termy 0.2.0"
git tag -a v0.2.0 -m "termy 0.2.0"

# 3. Build, sign, notarize, emit appcast
scripts/dist.sh
# → build/dist/termy-0.2.0.dmg  (signed, notarized, stapled, EdDSA-signed)
# → build/dist/appcast.xml      (with new <item> for 0.2.0)

# 4. Publish to GitHub Releases + push appcast to Pages
scripts/publish.sh
# → https://github.com/<user>/termy/releases/tag/v0.2.0
# → https://termy.nugo.cc/appcast.xml (Pages deploys in ~30s)

# 5. Push the source commit + tag last, once the release is live
git push --follow-tags
```

The source push is deliberately last — if any step in 3–4 fails, you haven't
contaminated the source repo with a release-tag that points at a release that
didn't ship. If `publish.sh` fails partway, `bump-version.sh`'s changes remain
as a local commit only; re-run the failed step, don't re-bump.

**Rollback**: if a release is live but broken, cut `0.2.1` following the same
flow. GitHub releases and the appcast are append-only in practice; we do not
unpublish. Users on `0.2.0` receive `0.2.1` on the next scheduled check.

## Key management

### Three signing layers (don't conflate them)

| Layer | Key | Purpose | Where it lives |
|---|---|---|---|
| Apple codesign | Developer ID cert (existing) | Gatekeeper trust | Build machine keychain |
| Apple notarization | Ticket (existing) | Apple-blessed, malware-scanned | Stapled into DMG |
| Sparkle EdDSA | New keypair | Update authenticity vs tampered feed | Private: keychain + 1Password. Public: baked into Info.plist |

The EdDSA layer is independent of Apple's. Even though every DMG is
Developer-ID-signed and notarized, Sparkle verifies its own signature before
installing — this defends against a compromised `termy.nugo.cc` serving a
differently-but-validly-signed DMG.

### One-time setup

1. Run `scripts/setup-sparkle.sh` — new script, part of this spec's
   deliverables. It downloads the pinned Sparkle 2.x tarball, verifies the
   SHA-256 against a hash committed in the script, extracts `bin/` into
   `scripts/vendor/sparkle/bin/`, and `pip install --user`s the `markdown`
   Python module used by `render-release-notes.py`. `.gitignore` adds
   `scripts/vendor/`.
2. `scripts/vendor/sparkle/bin/generate_keys --account termy` — writes private
   key to login keychain under account `termy`, prints the public key to stdout.
3. **Back up the private key** to 1Password before continuing:
   - `scripts/vendor/sparkle/bin/generate_keys --account termy -p` prints the
     existing private key.
   - Paste into a 1Password item titled "termy Sparkle signing key" with a
     note: "restore via `generate_keys --account termy --import-key` piping
     this value."
4. Paste the public key into `apps/termy/Info.plist` under `SUPublicEDKey`.
   Commit. This public key is forever.

### Loss-of-key recovery

If the EdDSA private key is lost (Mac wiped, 1Password item gone, no backup),
**there is no in-app recovery.** Existing installs accept updates only if
signed by the public key baked into their bundle. Recovery path:

1. Generate a new keypair.
2. Ship a new DMG with the new `SUPublicEDKey`.
3. Reach users out-of-band (email / website banner / Twitter) telling them to
   drag-replace `termy.app` manually.
4. Subsequent updates on the new install flow normally.

This is catastrophic. **Verify the 1Password backup exists and can be restored
before cutting the first public release.**

### Key rotation (deferred)

Sparkle 2 supports rotation via a second public-key Info.plist entry and a
staged roll-forward. Not planned for v1. Revisit only on suspected compromise.

## Hosting

### `termy-updates` repo (new)

Separate GitHub repo, public. Layout:

```
termy-updates/
├── appcast.xml        # overwritten by publish.sh each release
├── index.html         # optional landing page
└── README.md
```

The split from the main `termy` source repo is intentional: the Pages repo's
commit history becomes a clean audit trail of publication events.

### Cloudflare Pages

- Connect the `termy-updates` repo.
- Build command: `none`.
- Output directory: `/`.
- Custom domain: `termy.nugo.cc` (TLS managed by Cloudflare).
- Auto-deploys on every push to the main branch (typical Pages default).

### DNS

CNAME `termy.nugo.cc → <project>.pages.dev` on whatever manages `nugo.cc`.

### Verification after first setup

```bash
curl -I https://termy.nugo.cc/appcast.xml
# expect: HTTP/2 200, content-type: application/xml or text/xml
curl -s https://termy.nugo.cc/appcast.xml | head -30
# expect: valid appcast.xml <rss>...<channel>... with one <item>
```

## Error handling & offline behaviour

All handled by Sparkle's defaults. Spec makes them explicit so no future
reviewer has to dig into Sparkle's docs:

- **Feed unreachable** — silent retry on next scheduled check. No dialog.
- **Malformed appcast** — logged to console; skipped. Users never see an error.
  A bad appcast push doesn't spam existing users.
- **Signature mismatch / tampered DMG** — installer refuses, shows standard
  error dialog, logs to console. No silent downgrade to an unsigned build.
- **Manual `Check for Updates…` while offline** — standard "update check
  failed" dialog. Different from background (user-initiated ⇒ deserves
  feedback).
- **Skip This Version** — Sparkle writes to `NSUserDefaults`. Standard
  behaviour; we do not override.
- **Gatekeeper on swapped app** — the stapled notarization ticket travels
  with the bundle; Gatekeeper is happy. No extra code.

Not handled in v1 (relies on Sparkle defaults):

- Crash mid-install — Sparkle leaves old `.app` in place on swap failure.
- Network interruption mid-download — Sparkle resumes or retries on next
  check.

## Testing strategy

Three layers. No unit tests for Sparkle itself — it's a dependency.

### Layer 1: Local feed smoke test (pre-first-release, runbook)

1. Build an unnotarized DMG: `scripts/dist.sh --skip-notarize`.
2. Manually run `sign_update` against it.
3. Hand-craft a minimal `appcast.xml` with the signature, pointing at
   `http://localhost:8080/<dmg-name>`.
4. `cd build/dist && python3 -m http.server 8080` in one terminal.
5. In a debug build, temporarily override `SUFeedURL` via
   `defaults write app.termy.macos SUFeedURL http://localhost:8080/appcast.xml`
   (or edit Info.plist locally — do **not** commit).
6. Launch a copy of termy with an older `CFBundleShortVersionString` (edit
   Info.plist, re-build Debug). Click `Check for Updates…`.
7. Confirm the dialog appears, install proceeds, app relaunches at the new
   version.
8. Revert SUFeedURL override.

### Layer 2: First real-release dry run

1. Cut the first version that uses the pipeline (e.g. `v0.1.1`) through
   `dist.sh` + `publish.sh`.
2. On a clean macOS user account (or fresh VM), install the previous public
   DMG (`v0.1.0`).
3. Click `Check for Updates…`. Observe the full in-app flow.
4. If it fails: rollback by `rm -rf /Applications/termy.app && open <prior DMG>`
   and manually drag `termy.app` back.

### Layer 3: No automated tests for the updater wiring

The only new Swift code is ~30 lines in `Updater.swift`. If it compiles, the
menu item invokes `SPUStandardUpdaterController.checkForUpdates(_:)` and the
Info.plist keys are set, the integration works. Unit-testing this is a net
negative (mocking Sparkle is not worth the ceremony).

## Explicit non-goals

- Beta / prerelease channel. Add later via `SUAppcastChannel`.
- Delta (binary patch) updates. Add later via generate_appcast's delta flags;
  savings don't matter at current size.
- Preferences pane for user-visible update toggle. Users who want to disable
  can run `defaults write app.termy.macos SUEnableAutomaticChecks -bool false`.
- Key rotation UX. Add only if a compromise is suspected.
- Automated tests for the updater. Dependency code; not productive to cover.

## Open items (none blocking implementation)

- `GITHUB_REPO` value — owner/name of the termy GitHub repo, to be created as
  an implementation prerequisite. Not baked into the spec because the repo
  doesn't exist yet. Pick during implementation step 1.

## Implementation prerequisites

These happen once, before any code in the plan can ship:

1. Create GitHub repo for termy source (public or private). Set the remote.
2. Create GitHub repo `termy-updates`, clone sibling to the termy source.
3. Configure Cloudflare Pages on `termy-updates`, bind `termy.nugo.cc`, verify
   the feed URL serves a placeholder `appcast.xml` (even an empty one) over
   HTTPS.
4. Generate the EdDSA keypair, back up the private key to 1Password, paste
   public key into Info.plist.
5. Install the Sparkle tooling tarball under `scripts/vendor/sparkle/`.

The implementation plan (writing-plans skill, next step) breaks the code
changes into ordered, reviewable steps.
