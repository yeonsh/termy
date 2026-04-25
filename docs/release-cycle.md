# Release cycle

Operator checklist for cutting a termy release. Assumes one-time setup is done
— see [auto-update.md](./auto-update.md) for first-time configuration, key
management, and partial-failure recovery.

## Pre-flight

```bash
# Repo state
git status                 # clean
git log --oneline -5       # last commit is what you intend to ship

# Tooling
gh auth status             # logged in to github.com
xcrun notarytool history --keychain-profile termy-notary | head  # creds work
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
# expect: Developer ID Application: Bdrive Inc. (4M7G2HXTMV) in *login*, not /Library/Keychains/System.keychain
```

If the Developer ID identity is in System.keychain instead of login.keychain-db,
`dist.sh` will demand the admin password ~10× during Sparkle.framework signing.
Move it to login keychain (Keychain Access → System → Export → import into
login) before cutting a release.

## Cycle

1. **Bump version**
   ```bash
   scripts/bump-version.sh 0.1.1
   ```
   Rewrites `CFBundleShortVersionString`, `CFBundleVersion`, `MARKETING_VERSION`,
   `CURRENT_PROJECT_VERSION` in `project.yml` and stages it.

2. **Update CHANGELOG**
   Add a `## 0.1.1 — YYYY-MM-DD` section at the top with user-visible bullet
   points. Format must match the regex in `scripts/render-release-notes.py`
   (heading line is stripped, body becomes Sparkle `<description>` and GitHub
   release body).

3. **Commit + tag**
   ```bash
   git diff --staged project.yml
   git commit -am "termy 0.1.1"
   git tag -a v0.1.1 -m "termy 0.1.1"
   ```
   Tag locally only — push happens last.

4. **Build, sign, notarize, sign appcast**
   ```bash
   scripts/dist.sh
   ```
   Outputs `build/dist/termy-0.1.1.dmg` (notarized + stapled) and
   `build/dist/appcast.xml` (EdDSA-signed).

   For local-only verification without notarization, `--skip-notarize` builds
   a signed-but-unstapled DMG.

5. **Publish**
   ```bash
   scripts/publish.sh
   ```
   - `gh release create v0.1.1 build/dist/termy-0.1.1.dmg` on `yeonsh/termy`
   - copies `appcast.xml` into `$PAGES_REPO_PATH` (default `../termy-updates`),
     commits, pushes — Cloudflare Pages redeploys termy.nugo.cc

6. **Push source**
   ```bash
   git push --follow-tags
   ```
   Last on purpose: if `dist.sh` or `publish.sh` blows up mid-flow, only local
   state is dirty.

## Post-flight verification

```bash
# DMG is anonymously downloadable
curl -ILs https://github.com/yeonsh/termy/releases/download/v0.1.1/termy-0.1.1.dmg | head -1
# expect: HTTP/2 302  (redirect to S3 — that's success, not failure)

# Appcast is live on Pages
curl -fsSL https://termy.nugo.cc/appcast.xml | grep -E '<title>|sparkle:edSignature'

# GH release looks right
gh release view v0.1.1 --repo yeonsh/termy
```

Manual smoke test (recommended for every release):

1. Drag a previous-version termy.app from a backup or older install into
   `/Applications`, launch it.
2. termy → Check for Updates…
3. Sparkle should detect, download, EdDSA-verify, install, relaunch.
4. About window shows the new version.

If you don't have an older build handy, lie locally with the technique in
the design spec (custom appcast on `localhost:8080`, override SUFeedURL via
`defaults write app.termy.macos SUFeedURL …`).

## When something goes wrong

- **Notarization rejects** — check `xcrun notarytool log <submission-id>
  --keychain-profile termy-notary developer_log.json`. Common causes: an
  embedded binary missing the hardened runtime flag, or a stale cached signature.
- **Keychain password requested 10×** — Developer ID private key is in
  System.keychain. Move to login keychain (see Pre-flight).
- **`gh release create` succeeds but `git push` to Pages repo fails** — see
  the partial-failure recovery block in [auto-update.md](./auto-update.md).
  Don't delete the GH release; re-push the appcast manually.
- **Sparkle rejects the update on the client** — verify `SUPublicEDKey` in
  the *installed* app's `Info.plist` matches the key used to sign the DMG.
  If they diverge (key rotation), every existing install ignores updates
  silently. Loss-of-key recovery is in auto-update.md.

## Rollback

Append-only. To unship 0.1.1, cut 0.1.2 with the fix. Existing 0.1.1 users
upgrade on the next ~24h scheduled check or immediately on Check for
Updates….
