# Public rollout — Snappy 1.1

The order matters more than any individual step. Two things are irreversible
(losing the signing key, publishing a bad asset) and three only work once the
repository is public, so the sequence below is not a suggestion.

State this was written against: repo **private**, version **1.1 (build 2)**,
minimum **macOS 12**, release notes written, Sparkle key generated, appcast not
yet produced, `origin` carrying one tag (`v1.0`).

---

## Development builds

`scripts/run-dev.sh` builds and runs the app you are working on. It never
touches `/Applications`: in Debug the app is "Snappy Dev"
(`com.simarholonipaa.snappy.dev`, URL scheme `snappy-dev`, no updater), so it
has its own preferences, its own Accessibility grant and its own place in the
permissions list. The installed release keeps running beside it and keeps
updating itself through Sparkle.

The script refuses to run a build carrying the released identifier, which is
what a `--release` build would produce.

## 0. Before anything

**Back up the Sparkle private key.** It lives in the login keychain as service
`https://sparkle-project.org`, account `ed25519`. Export it somewhere offline.

Every copy of Snappy verifies updates against the public half compiled into it.
Lose the private half and you can never ship an update to anyone running 1.1 or
later — not "it gets harder", it ends. This is the only step with no recovery.

**Re-check for secrets.** Nothing has ever been committed, but the sweep is
cheap and this is the last moment it is free:

```bash
git log --all --pretty=format: --name-only --diff-filter=A | sort -u \
  | grep -iE '\.p12$|\.cer$|\.mobileprovision$|\.pem$|\.env$'
git grep -nI "knollsoft\|ryanhanson\.dev\|travismarceau\.com"
```

Both should be empty.

---

## 1. Build and notarize — before going public

Nothing here depends on the repo being public, so failures cost nothing.

```bash
./scripts/build-direct.sh
```

It refuses to run if `SUPublicEDKey` is empty, if `v1.1` already exists on
`origin`, if the build number does not exceed what `site/appcast.xml` already
advertises, or if release notes for the tag are missing. On success it produces
a notarized, stapled `build/Snappy.zip` and writes `site/appcast.xml` with the
notes embedded and the enclosure pointing at the GitHub release URL.

**Check the appcast before it goes anywhere:**

```bash
grep -E 'sparkle:version|minimumSystemVersion|enclosure url' site/appcast.xml
```

Expect `2`, `12.0`, and
`https://github.com/travismarceau/snappy/releases/download/v1.1/Snappy.zip`.

---

## 2. Go public

**Do this before publishing the release.** Release assets on a private
repository are not publicly downloadable, and three things point at one:

- the site's download button → `/releases/latest/download/Snappy.dmg.zip`
- the appcast enclosure → `/releases/download/v1.1/Snappy.zip`
- every future Sparkle update

Flip visibility in the repository settings. Then confirm GitHub now reads the
licence as MIT rather than "Other" — that was the point of keeping both
copyright lines and dropping the prose line above them.

---

## 3. Publish the release

```bash
gh release create v1.X build/Snappy.zip build/Snappy.dmg.zip \
  -R travismarceau/snappy \
  --title "Snappy 1.X" \
  --notes-file site/releases/v1.X.md
```

**Attach both files.** `Snappy.zip` is what Sparkle downloads and what the
appcast signs; `Snappy.dmg.zip` is what the website's download button points at,
through `/releases/latest/download/Snappy.dmg.zip`. The outer ZIP preserves
the disk image's custom Finder icon when downloaded. Forget it and the site's
button 404s the moment this release becomes "latest" — which happened with
1.2.1, whose release initially carried only the Sparkle zip. The app and disk
image are notarized and stapled by `build-direct.sh` before the DMG is zipped.

**`-R` is not optional.** This repo still has an `upstream` remote pointing at
`rxhanson/Rectangle`, and with two remotes and no default set `gh` picks that
one — the first attempt here tried to create the release on Rectangle and only
failed because there is no write access to it. `gh repo set-default
travismarceau/snappy` fixes it for good; pass `-R` anyway.

The tag is created server-side, which is why `build-direct.sh` checks `origin`
rather than the local repo — re-running the build after this point must fail,
because replacing the asset would invalidate the signature the live appcast
advertises.

Then commit and push the appcast and notes:

```bash
git add site/appcast.xml site/releases/
git commit -m "Publish the 1.1 appcast"
git push
./scripts/deploy-site.sh
```

DigitalOcean normally deploys the push automatically through the native GitHub
source in `.do/app.yaml`. The explicit script is still required for releases:
it waits for the deployment it creates and then proves the public feed serves
the new build. An older deployment being `ACTIVE` proves neither.

---

## 4. Cut the website over

No dashboard needed — the checked-in app spec is reviewable and reproducible:

```bash
doctl apps list --format ID,Spec.Name --no-header | grep getsnappy   # -> app id
doctl apps update <app-id> --spec .do/app.yaml --update-sources --wait
```

The native `github:` source is intentional. Unlike a plain `git:` clone URL, it
supports `deploy_on_push: true` and lets DigitalOcean receive push events.

The spec has no `catchall_document`, on purpose — see `site/README.md`. Unknown
paths 404, and `/Snappy.zip` redirects to the latest GitHub release so the 1.0
download link keeps working.

Note what changes for anyone with a bookmark: `getsnappy.fyi/Snappy.zip` stops
existing. The zip is no longer committed to the site; the download button goes
to GitHub Releases. That is deliberate — ~4 MB per release does not belong in
git history — but it does mean that one URL breaks.

---

## 5. Verify

```bash
./scripts/deploy-site.sh
```

Run the script rather than checking deployment status or HTTP status codes by
hand. It waits for the deployment it creates, waits for the public feed's build
number, then runs the full verifier. The verifier tests
content type, that the body is RSS, that the advertised build matches the
project, that the notes are embedded rather than linked, that the signature is
present, and that the enclosure actually resolves.

All eight checks must pass before the release is announced.

Do not spot-check a release asset with `curl -I`. GitHub redirects asset
downloads to its object store and a HEAD against that redirect answers 404 for
an asset that is public and downloads perfectly — which looked exactly like a
failed release here until it was checked with a real GET.

---

## 6. Afterwards

- **Archive `travismarceau/getsnappy-site`** once the site is confirmed serving
  from this repo. Leaving it live leaves a second copy to drift, which is the
  problem that put the website in here in the first place.
- Watch the first Sparkle update land. 1.1 → 1.2 is the first real exercise of
  the updater in the wild; the dry run in `site/README.md` covers it locally
  beforehand.

---

## What 1.0 users experience

Worth being clear-eyed about, because it is the roughest upgrade this app will
ever ask for.

**1.0 has no updater at all.** Sparkle was not linked into it, so nothing will
tell those users 1.1 exists. The website is their only path, and the upgrade is
a manual download. "This is the last release you have to download by hand" in
the release notes is true going forward — 1.1 onwards auto-update — but 1.0 to
1.1 is by hand.

**They must re-grant Accessibility.** The bundle identifier changed from
`com.travismarceau.snappy` to `com.simarholonipaa.snappy`, and macOS keys the
grant to the identifier and code signature with no way to transfer it. Settings
migrate automatically on first launch; the permission cannot. A user who skips
it gets an app that launches and then silently moves nothing — which is exactly
the failure that is hardest to self-diagnose, so the release notes lead with it.

**macOS 12 is now the floor**, up from 10.15. Anyone on 10.15 or 11 keeps 1.0
and will never be offered 1.1: `generate_appcast` writes
`sparkle:minimumSystemVersion` from the bundle, and Sparkle checks it before
proposing anything.

---

## If something is wrong after publishing

The appcast is the kill switch. Remove `site/appcast.xml`, or revert it to the
previous release, and push — Sparkle stops offering the update immediately,
because the feed is fetched fresh every check. Fix, bump
`CURRENT_PROJECT_VERSION`, and cut a new release. **Never re-upload an asset to
an existing tag**: the live appcast carries a signature for the exact bytes it
described, and replacing them means every client that already fetched the feed
sees a signature mismatch and refuses the update.
