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
`targets.termy.info.properties.SUPublicEDKey`. Run `xcodegen generate` to
propagate it into the generated `Info.plist`, then commit `project.yml`:

```bash
xcodegen generate
git commit -am "project: set SUPublicEDKey for Sparkle signatures"
```

Without this step, `dist.sh` will halt at the preflight check.

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

## Partial-failure recovery

If `publish.sh` fails *after* the GitHub release is created but *before* the
Pages push completes (network hiccup, auth lapse), the GH release is live but
no client will see it. A re-run of `publish.sh` fails because the tag exists.
Recover by pushing the appcast manually:

```bash
cp build/dist/appcast.xml ../termy-updates/appcast.xml
git -C ../termy-updates commit -am "termy <version>"
git -C ../termy-updates push
```

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
