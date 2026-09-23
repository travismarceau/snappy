/// Updater.swift
///
/// Sparkle, for the direct-download channel.
///
/// Snappy ships direct-only: the App Sandbox denies the mach lookup of
/// `com.apple.axserver`, so a sandboxed build reports Accessibility as granted
/// and then silently moves nothing (see `docs/APP_STORE.md`). That closes the
/// Mac App Store route, and with it the usual reason to keep a self-updater out
/// of the bundle — so Sparkle is linked unconditionally rather than hidden
/// behind a build configuration that only one channel would ever use.
///
/// Without this, a 1.0 user has no way to learn 1.1 exists short of revisiting
/// the website.

import Cocoa
import Sparkle

/// Owns the Sparkle controller for the life of the process.
///
/// `SPUStandardUpdaterController` starts the updater as soon as it is created,
/// so it is built once from `AppDelegate` and held; letting it deallocate would
/// silently stop update checks.
final class SnappyUpdater: NSObject {

    static let shared = SnappyUpdater()

    /// A development build must never update itself. Its identifier ends in
    /// `.dev`, it is not what the appcast describes, and letting Sparkle replace
    /// it with the released app would quietly destroy the thing being worked on.
    static var isEnabled: Bool {
        !(Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        super.init()
    }

    /// Whether Sparkle checks on its own schedule. Sparkle persists this itself
    /// under `SUEnableAutomaticChecks`, which is why `Defaults` already carries
    /// that key — it predates this file and survived Sparkle's removal.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The menu item and the Settings button both land here.
    func checkForUpdates() {
        guard Self.isEnabled else { return }
        controller.checkForUpdates(nil)
    }

    /// True when the app can actually update itself: a build running from a
    /// read-only mount, or one still in the Xcode build directory, cannot, and
    /// offering the button there only produces a confusing failure.
    var canCheckForUpdates: Bool {
        Self.isEnabled && controller.updater.canCheckForUpdates
    }
}
