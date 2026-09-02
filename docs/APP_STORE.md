# Snappy — Mac App Store submission

## What's already done in the codebase

- **Rebranded** to Snappy: bundle id `com.travismarceau.snappy`, display
  name, URL scheme `snappy://`, support dir `~/…/Application Support/Snappy`,
  config file `SnappyConfig.json`, all user-facing strings and the whole
  `Main.xcstrings` catalog, the app icon (`SnappyIcon`), the login-helper
  bundle id (`com.travismarceau.snappy.Launcher`). Internal Swift module stays
  `Rectangle` (via `PRODUCT_MODULE_NAME`) — invisible to users, avoids a risky refactor.
- **Attribution kept** for MIT compliance: `LICENSE` (Ryan Hanson / Spectacle /
  Eric Czarny) is unchanged, `NOTICE.md` added, the About panel credits Rectangle
  + Spectacle, `NSHumanReadableCopyright` names them.
- **Welcome / recommended-settings pop-up removed.** First run now just applies
  the recommended defaults directly (`alternateDefaultShortcuts` on,
  `subsequentExecutionMode = acrossMonitor`).
- **Sparkle removed entirely** (SPM package, code, Info.plist `SU*` keys, the
  "Check for Updates" menu item and settings controls). Updates go through the
  App Store.
- **Release config = the MAS build**: `Snappy.app`, App Sandbox
  (`com.apple.security.app-sandbox` + `files.user-selected.read-write`), hardened
  runtime, `ITSAppUsesNonExemptEncryption = false`, `MARKETING_VERSION = 1.0`,
  `CURRENT_PROJECT_VERSION = 1`, team `P78K4VHEL3`, automatic signing.
- Debug config is the local dev build (ad-hoc, unsandboxed, `Snappy.app`).
- `xcodebuild -configuration Release build` and `… test` both pass (328 tests).

## Must verify before you submit (cannot be checked from the build alone)

1. **Sandboxed window management actually works.** The free Rectangle is *not*
   on the App Store; Rectangle Pro (a separate sandboxed codebase) is. Sandboxed
   apps *can* drive the Accessibility API to move other apps' windows once the
   user grants Accessibility (Magnet, Rectangle Pro, Swish, Moom all do it), but
   **you must run the signed, provisioned Release build and confirm every feature
   still works** — snapping, drag-to-edge, Todo mode, multi-display, the
   placement overlay. If something is blocked, you may need
   `com.apple.security.automation.apple-events` + `NSAppleEventsUsageDescription`,
   or to drop a feature.
2. **App Review Guideline 4.1 (Copycats).** Snappy is a rebranded fork of
   Rectangle, whose author ships apps on the same store. The placement feature
   differentiates it, but rejection is a real possibility — be ready to explain
   what's original.
3. `~/Library/Application Support/Snappy` under the sandbox resolves to the
   app *container*, not the real path. `loadFromSupportDir()` still works but the
   drop-in-a-config-file workflow changes. Test import/export via the panels.
4. The `WelcomeViewController` storyboard scene is now orphaned (never shown) —
   harmless, but you can delete it for tidiness.

## Human steps (portal / Xcode, not code)

1. **App Store Connect**: create the app record with bundle id
   `com.travismarceau.snappy`, name "Snappy", primary category
   Productivity, set up pricing.
2. **Certificates / profiles**: in Xcode → the Rectangle target → Signing &
   Capabilities, "Automatically manage signing", Team = your team. Xcode creates
   the "Mac App Store" provisioning profile on first Archive.
3. **Archive & upload**: Product → Archive (Release), then Organizer →
   Distribute App → App Store Connect → Upload. Or:
   `xcodebuild -scheme Rectangle -configuration Release archive -archivePath build/Snappy.xcarchive`
   then `xcodebuild -exportArchive -archivePath build/Snappy.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export`
   with `ExportOptions.plist` method `app-store`.
4. **Metadata**: description, keywords, support URL, marketing URL, **privacy
   policy URL** (required), screenshots (1280×800 or 1440×900, at least one),
   an App Preview optional.
5. **App Privacy**: Snappy collects no data — fill in "Data Not Collected".
6. **Export compliance**: `ITSAppUsesNonExemptEncryption` is already `false` in
   Info.plist, so no extra questionnaire.
7. **Accessibility usage**: the app needs the user to grant Accessibility; make
   sure your review notes explain this and how to test (System Settings →
   Privacy & Security → Accessibility → enable Snappy).
8. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` for every subsequent
   upload.
