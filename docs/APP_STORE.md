# Snappy — release checklist

Snappy is a keyboard-first window placement app derived from **Rectangle**
(MIT). See `NOTICE.md` / `LICENSE` for attribution.

## Done in the codebase

**Identity & compliance**
- Bundle id `com.travismarceau.snappy`, display name "Snappy", URL scheme
  `snappy://`, support dir `~/Library/Application Support/Snappy`, config file
  `SnappyConfig.json`, icon `SnappyIcon`, login helper
  `com.travismarceau.snappy.Launcher`. Swift module stays `Rectangle`
  internally (`PRODUCT_MODULE_NAME`).
- `LICENSE` kept verbatim; `NOTICE.md` added; the About panel and
  `NSHumanReadableCopyright` credit Rectangle + Spectacle.

**De-Rectangle-ification (4.1 copycat mitigation)**
- The whole **Shortcuts settings tab is gone**, along with all ~130 preset
  global chord shortcuts (they no longer bind) and the "Left Half / Maximize /
  First Third / …" list in the status menu. Window placement is entirely the
  leader-key grid overlay. Settings tabs: **Snap Areas · Placement · General**.
- The Placement tab has a **Placements | Layouts** switch. **Multi-window
  layouts** (one key arranges several apps' windows at once) is a feature
  Rectangle has no equivalent for.
- Welcome / recommended-settings modal removed. Sparkle removed entirely.

**Build config**
- **Release** = the Mac App Store build: `Snappy.app`, App Sandbox
  (`app-sandbox` + `files.user-selected.read-write`), hardened runtime,
  `ITSAppUsesNonExemptEncryption=false`, v1.0 (1), team `P78K4VHEL3`,
  automatic signing. `xcodebuild -configuration Release archive
  -allowProvisioningUpdates` succeeds.
- **Debug** = local dev build (ad-hoc, unsandboxed).
- Direct-download build via `scripts/build-direct.sh` (Developer ID + notarize).

## Two channels

### Mac App Store (Release)
1. App Store Connect: create the app record — bundle id
   `com.travismarceau.snappy`, category Productivity.
2. Xcode ▸ Rectangle target ▸ Signing & Capabilities: automatic signing, your
   team. First Archive creates the Mac App Store provisioning profile.
3. Product ▸ Archive ▸ Organizer ▸ Distribute App ▸ App Store Connect. Or
   `xcodebuild -exportArchive … -exportOptionsPlist ExportOptions-AppStore.plist`
   (needs an Apple ID in Xcode ▸ Settings ▸ Accounts, or an ASC API key).

### Direct download (notarized Developer ID)
1. Create a **Developer ID Application** certificate (Xcode ▸ Settings ▸
   Accounts ▸ Manage Certificates ▸ +, or Organizer ▸ Distribute ▸ Developer
   ID once). *You don't have one yet — `security find-identity` shows only
   "Apple Development".*
2. `xcrun notarytool store-credentials snappy-notary --apple-id … --team-id
   P78K4VHEL3 --password <app-specific-password>`.
3. `./scripts/build-direct.sh` → notarized, stapled `build/Snappy.zip`.
   - It reuses the Release config (sandboxed) but signs Developer ID. If
     on-device testing shows the sandbox blocks a feature, add a dedicated
     `Direct` build configuration pointing `CODE_SIGN_ENTITLEMENTS` at
     `Rectangle/RectangleDirect.entitlements` (no sandbox) — that file is
     already in the repo for this.

## Must verify on-device before submitting

1. **The sandboxed Release build actually manages windows.** Run
   `./scripts/verify-sandbox.sh` — see *Sandbox verification* below for what it
   does and why a plain Release build is enough to test it. Record the result in
   that section. If it fails: add `com.apple.security.automation.apple-events` +
   `NSAppleEventsUsageDescription`, or ship direct-only non-sandboxed.
2. **4.1 Copycats** is still a judgement call. Mitigations in place: own name,
   own icon, the Shortcuts pane / preset chords / action menu are gone, the
   primary UI is the grid overlay + layout editor, and multi-window layouts is
   original. Keep "based on Rectangle" out of the store description (it's in
   About + LICENSE). The direct channel is the hedge.
3. Import/export config via the panels under the sandbox (paths resolve to the
   app container).

## Sandbox verification

Every bit of window-management testing up to now has been against the **Debug**
build, and `Rectangle/Rectangle.entitlements` is an empty dict — no sandbox at
all. The App Store build is sandboxed via
`Rectangle/RectangleRelease.entitlements`. Sandbox + Accessibility is known to
work for Magnet and Rectangle Pro, but that is evidence about their binaries,
not this one.

**A plain Release build is enough to test it**, with none of the account-side
export blockers in the way — those gate distribution, not local execution:

```
CODE_SIGN_ENTITLEMENTS = Rectangle/RectangleRelease.entitlements   ← sandbox: YES
CODE_SIGN_IDENTITY     = Apple Development                         ← stable, TCC-trustable
```

`com.apple.security.app-sandbox` needs no provisioning profile, and Apple
Development signing gives a stable designated requirement, so TCC accepts and
remembers the Accessibility grant.

```
./scripts/verify-sandbox.sh                # build, assert, install, then guided tests
./scripts/verify-sandbox.sh --skip-build   # re-run just the move tests
```

It builds Release, **asserts the signed binary really carries the sandbox and
user-selected-file entitlements** (and that the nested `RectangleLauncher.app`
is sandboxed too — the store requires it of nested code), installs to
`/Applications`, then walks you through granting Accessibility and pressing the
placement keys. Before/after window geometry comes from
`scripts/window-frames.swift`, which reads `CGWindowListCopyWindowInfo` — window
bounds are not gated by Screen Recording, so the observer needs no permission of
its own and cannot be fooled by the grant it is testing. It reports every
non-Snappy window whose frame changed.

### Known sandbox effects (audited, not blockers)

- `checkForProblematicApps` (`AppDelegate.swift:188`) reads other apps' bundles
  via `Bundle(url:)`. The sandbox denies that, so the MATLAB / Illustrator
  conflict warning silently won't fire. Cosmetic.
- `StageUtil.isStageStripVisible` matches `kCGWindowOwnerName == "WindowManager"`.
  Owner names are *not* redacted without Screen Recording (only `kCGWindowName`,
  the title, is, and it is never read), so this should work — worth an eyes-on
  check if you use Stage Manager.
- Import/Export and the Layouts app picker (`PlacementConfigViews.swift:584`, an
  `NSOpenPanel` at `/Applications`) rely on
  `com.apple.security.files.user-selected.read-write`. Exercise both by hand.

### Result

> Not yet run. Record here: date, macOS version, and the before/after frames the
> script prints.

## Support / privacy site — live

`store/site.html` is deployed at **https://getsnappy.fyi/** and
**https://www.getsnappy.fyi/** — both HTTPS, valid certs. Stack:

- GitHub repo `travismarceau/getsnappy-site` (public) → `index.html` mirrors
  `store/site.html`.
- DigitalOcean App Platform static site, app `getsnappy`
  (`3229cad9-40e1-4641-8910-8c768902710d`), free tier, NYC. Redeploys on push
  to `main`.
- DNS at Porkbun (nameservers unchanged): apex `ALIAS` + `www` `CNAME` →
  `getsnappy-gztct.ondigitalocean.app`. The apex's stock `ALIAS →
  pixie.porkbun.com` (parking) had to be repointed via the Porkbun API.

Listing URLs (in `store/listing.md`): support `https://getsnappy.fyi/#support`,
marketing `https://getsnappy.fyi/`, privacy `https://getsnappy.fyi/#privacy`.

## Metadata (App Store Connect)

- Every field is written out in `store/listing.md`, ready to paste.
- **App name is `Snappy Window Manager`, not `Snappy`.** Plain "Snappy" is taken
  by a live iOS app (Delisa srl), and App Store Connect enforces record-name
  uniqueness across the whole store, not per-platform. The app on disk is
  unchanged — only the store record's name differs. Reasoning is recorded under
  *Name* in `store/listing.md`.
- **Screenshots**: `./scripts/capture-screenshots.sh` then
  `uv run design/compose_screenshots.py` → six 2880×1800 frames in
  `store/screenshots/`. ASC accepts only 1280×800 / 1440×900 / 2560×1600 /
  2880×1800; this display is 3456×2234, so raw captures are never a valid size
  and always need composing. Order and captions are in `store/listing.md`.
- App Privacy: "Data Not Collected".
- Review notes: explain the Accessibility permission and how to grant it
  (System Settings ▸ Privacy & Security ▸ Accessibility ▸ Snappy).
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` per upload.

## Known issue

`RectangleTests/ShortcutRecordingObserverTests` (upstream Todo-mode shortcut
tests) is **flaky in the full-suite run** on machines where `⌘⌃⌥⇧`+letter
combos are already grabbed (Karabiner, other window tools). The tests race on
`MASShortcutMonitor.isShortcutRegistered` and were previously "warmed" by the
window-chord bindings we removed. They pass reliably **in isolation**
(`xcodebuild … -only-testing:RectangleTests/ShortcutRecordingObserverTests`)
and on a clean machine. All other suites, including the 23 placement/layout
tests, are deterministic and green.

## Follow-up cleanup (not blocking)

- `Rectangle/PrefsWindow/PrefsViewController.swift` and the
  `WelcomeViewController` storyboard scene are dead (never instantiated) — safe
  to delete.
- `WindowAction.alternateDefault` / `spectacleDefault` tables are unused.
