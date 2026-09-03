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

1. **The sandboxed Release build actually manages windows** — snapping,
   drag-to-edge, Todo, multi-display, the placement overlay, **and multi-window
   layouts** (`AccessibilityElement(bundleId:)` reaching other apps under the
   sandbox). Sandboxed AX window control works for Magnet / Rectangle Pro /
   Swish, but confirm it here. If blocked: add
   `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`,
   or ship direct-only non-sandboxed.
2. **4.1 Copycats** is still a judgement call. Mitigations in place: own name,
   own icon, the Shortcuts pane / preset chords / action menu are gone, the
   primary UI is the grid overlay + layout editor, and multi-window layouts is
   original. Keep "based on Rectangle" out of the store description (it's in
   About + LICENSE). The direct channel is the hedge.
3. Import/export config via the panels under the sandbox (paths resolve to the
   app container).

## Support / privacy site — live

`store/site.html` is deployed at **https://www.getsnappy.fyi/** (valid cert,
serving today). The bare apex `getsnappy.fyi` is *not* working — Porkbun's ALIAS
flattening returns Porkbun parking IPs instead of the DO target; fixing it
requires switching the domain to DigitalOcean nameservers. `www.` is sufficient
for the App Store listing. Stack:

- GitHub repo `travismarceau/getsnappy-site` (public) → `index.html` mirrors
  `store/site.html`.
- DigitalOcean App Platform static site, app `getsnappy`
  (`3229cad9-40e1-4641-8910-8c768902710d`), free tier, NYC. Redeploys on push
  to `main`.
- DNS at Porkbun: `www` CNAME + apex ALIAS → `getsnappy-gztct.ondigitalocean.app`.

Listing URLs (in `store/listing.md`): support `https://www.getsnappy.fyi/#support`,
marketing `https://www.getsnappy.fyi/`, privacy `https://www.getsnappy.fyi/#privacy`.

## Metadata (App Store Connect)

- Description, keywords, support URL, marketing URL, **privacy policy URL**
  (required). Screenshots ≥ 1 (1280×800 or 1440×900).
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
