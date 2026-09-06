/// PlacementMode.swift
///
/// The "leader key" runtime for Divvy-style window placement:
///   1. `PlacementModeManager` owns a single global shortcut (via MASShortcut,
///      like `TodoManager`) that toggles placement mode on.
///   2. `PlacementModeController` shows the on-screen grid pane, captures the
///      next single keystroke with an `ActiveEventMonitor`, resolves the bound
///      `GridPlacement` to a rect and hands it to the normal execution pipeline
///      through `WindowAction.specified.postPlacement(...)`.

import Cocoa
import Carbon.HIToolbox
import MASShortcut

// MARK: - Manager (global leader shortcut)

class PlacementModeManager {

    static let defaultsKey = "enterPlacementMode"
    static let defaultsKeys = [defaultsKey]

    private static var sessionActive = true
    private static var suspended = false

    init() {
        PlacementModeManager.initShortcut()
        PlacementModeManager.registerUnregisterShortcut()
    }

    func reloadFromDefaults() {
        PlacementModeManager.registerUnregisterShortcut()
    }

    /// Seed a sensible default (⌃⌥Space) the first time, matching Rectangle's
    /// `⌃⌥` shortcut family.
    static func initShortcut() {
        guard UserDefaults.standard.dictionary(forKey: defaultsKey) == nil,
              let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))
        else { return }
        let shortcut = MASShortcut(keyCode: kVK_Space,
                                   modifierFlags: [.control, .option])
        UserDefaults.standard.set(dictTransformer.reverseTransformedValue(shortcut), forKey: defaultsKey)
    }

    static func registerUnregisterShortcut() {
        if Defaults.placementModeEnabled.userEnabled, sessionActive, !suspended, isBindable() {
            MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: defaultsKey, toAction: {
                PlacementModeController.shared.activate()
            })
        } else {
            MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: defaultsKey)
        }
    }

    static func setShortcutBindingsSessionActive(_ isActive: Bool) {
        guard sessionActive != isActive else { return }
        sessionActive = isActive
        if !isActive { PlacementModeController.shared.deactivate() }
        registerUnregisterShortcut()
    }

    static func setShortcutBindingsSuspended(_ isSuspended: Bool) {
        guard suspended != isSuspended else { return }
        suspended = isSuspended
        if isSuspended { PlacementModeController.shared.deactivate() }
        registerUnregisterShortcut()
    }

    private static func isBindable() -> Bool {
        guard let shortcut = shortcut(for: defaultsKey) else { return true }
        return AppShortcutConflict.conflict(for: shortcut, ignoringDefaultsKey: defaultsKey) == nil
    }

    static func shortcut(for defaultsKey: String, userDefaults: UserDefaults = .standard) -> MASShortcut? {
        guard
            let shortcutDict = userDefaults.dictionary(forKey: defaultsKey),
            let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)),
            let shortcut = dictTransformer.transformedValue(shortcutDict) as? MASShortcut
        else { return nil }
        return shortcut
    }

    static func getKeyDisplay() -> (String?, NSEvent.ModifierFlags)? {
        guard let shortcut = shortcut(for: defaultsKey) else { return nil }
        return (shortcut.keyCodeStringForKeyEquivalent, shortcut.modifierFlags)
    }
}

// MARK: - Controller (modal pane + single-key capture)

final class PlacementModeController {

    static let shared = PlacementModeController()
    private init() {}

    /// Guards `active`, `finishing` and `keymap`: the event-tap thread reads
    /// them from `shouldSwallow` while the main thread mutates them.
    private let stateLock = NSLock()
    private var active = false
    private var keymap = PlacementKeymap.empty

    private var monitor: ActiveEventMonitor?
    private var overlay: PlacementOverlayPanel?
    private var timeoutWorkItem: DispatchWorkItem?
    private var revealWorkItem: DispatchWorkItem?
    /// True during the brief flash between a placement and teardown, so the
    /// event tap keeps swallowing keys even though `active` is already false.
    private var _finishing = false

    private var targetElement: AccessibilityElement?
    private var targetWindowId: CGWindowID?
    private var baseScreen: NSScreen?

    private var isActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return active
    }
    private func setActive(_ value: Bool) {
        stateLock.lock(); active = value; stateLock.unlock()
    }
    private var currentKeymap: PlacementKeymap {
        stateLock.lock(); defer { stateLock.unlock() }
        return keymap
    }
    private func setKeymap(_ value: PlacementKeymap) {
        stateLock.lock(); keymap = value; stateLock.unlock()
    }
    private var finishing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _finishing
    }
    private func setFinishing(_ value: Bool) {
        stateLock.lock(); _finishing = value; stateLock.unlock()
    }

    // MARK: Activation

    func activate() {
        DispatchQueue.main.async { [weak self] in self?.beginSession() }
    }

    private func beginSession() {
        // Pressing the leader shortcut again is a toggle: dismiss, don't re-arm.
        if isActive || finishing { endSession(); return }
        guard Defaults.placementModeEnabled.userEnabled else { return }

        let map = Defaults.placementKeymap.typedValue ?? .empty
        guard map.hasAnyAssignedKey else {
            NSSound.beep()
            return
        }
        setKeymap(map)

        targetElement = AccessibilityElement.getFrontWindowElement()
        targetWindowId = targetElement?.getWindowId()

        let usable = Defaults.useCursorScreenDetection.enabled
            ? ScreenDetection().detectScreensAtCursor()
            : ScreenDetection().detectScreens(using: targetElement)
        guard let screen = usable?.currentScreen ?? NSScreen.main else {
            NSSound.beep()
            return
        }
        baseScreen = screen

        let leader = PlacementModeManager.shortcut(for: PlacementModeManager.defaultsKey)
        let panel = PlacementOverlayPanel(screen: screen, keymap: map, leaderShortcut: leader)
        panel.present()
        overlay = panel

        let monitor = ActiveEventMonitor(
            mask: [.keyDown],
            filterer: { [weak self] event in self?.shouldSwallow(event) ?? false },
            handler: { [weak self] event in self?.handleKey(event) }
        )
        monitor.start()
        self.monitor = monitor

        setActive(true)
        scheduleMapReveal()
        rearmTimeout()
    }

    private func scheduleMapReveal() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
        switch Defaults.placementMapReveal.value {
        case .always:
            overlay?.revealMap(animated: false)
        case .never:
            break
        case .afterDelay:
            let delay = max(0.05, Double(Defaults.placementMapRevealDelay.value))
            let item = DispatchWorkItem { [weak self] in self?.overlay?.revealMap(animated: true) }
            revealWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: Event handling

    /// Runs on the event-tap thread. Returning true consumes the event so it
    /// never reaches the focused app.
    private func shouldSwallow(_ event: NSEvent) -> Bool {
        guard isActive || finishing, event.type == .keyDown else { return false }
        guard isActive else { return true } // in the flash tail: swallow everything, act on nothing
        if Int(event.keyCode) == kVK_Escape { return true }
        let mods = event.modifierFlags.rawValue & placementModifierMask
        let code = Int(event.keyCode)
        if currentKeymap.binding(forKeyCode: code, modifierFlags: mods) != nil { return true }
        if currentKeymap.layout(forKeyCode: code, modifierFlags: mods) != nil { return true }
        // Bare keystrokes are the "any single key" the user means to capture;
        // swallow them. Unrecognised modified combos (⌘Tab, ⌘Q…) pass through so
        // the user can still switch or quit apps, useful in sticky mode.
        return mods == 0
    }

    /// Dispatched to the main thread by `ActiveEventMonitor`.
    private func handleKey(_ event: NSEvent) {
        guard isActive else { return }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            deactivate()
            return
        }
        let mods = event.modifierFlags.rawValue & placementModifierMask

        if let binding = currentKeymap.binding(forKeyCode: keyCode, modifierFlags: mods) {
            revealWorkItem?.cancel()
            overlay?.flash(binding)
            place(binding)
            finishPlacement()
        } else if let layout = currentKeymap.layout(forKeyCode: keyCode, modifierFlags: mods) {
            revealWorkItem?.cancel()
            let outcome = applyLayout(layout)
            overlay?.flash(layout: layout, outcome: outcome)
            finishPlacement(holdingFor: outcome.isComplete ? 0.24 : 1.5)
        } else {
            NSSound.beep()
            // An unrecognised key almost always means "I forget my map" — show it.
            revealWorkItem?.cancel()
            overlay?.revealMap(animated: true)
            rearmTimeout()
        }
    }

    /// Shared sticky-vs-dismiss tail after a key resolves to a placement or
    /// layout. `holdingFor` is how long the flash stays up before teardown -
    /// longer when there is a message to read.
    private func finishPlacement(holdingFor hold: TimeInterval = 0.24) {
        if Defaults.placementPaneSticky.enabled {
            // The user will focus a different window before the next key.
            targetElement = AccessibilityElement.getFrontWindowElement()
            targetWindowId = targetElement?.getWindowId()
            rearmTimeout()
        } else {
            // Let the flash play, then tear down.
            setActive(false)
            setFinishing(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                self?.endSession()
            }
        }
    }

    private func place(_ binding: PlacementBinding) {
        guard let base = baseScreen else { return }
        let map = currentKeymap
        let screen = resolveScreen(for: binding.placement, base: base)
        let rect = binding.placement.resolve(
            in: screen.adjustedVisibleFrame(),
            grid: map.grid,
            outerMargin: map.outerMargin,
            innerGap: map.innerGap
        )
        WindowAction.specified.postPlacement(
            rect: rect,
            screen: screen,
            windowElement: targetElement,
            windowId: targetWindowId
        )
    }

    /// What a layout managed to do, so the overlay can draw only the regions it
    /// actually filled and say why the rest are empty.
    struct LayoutOutcome {
        var placed: [GridPlacement] = []
        /// The app isn't running at all.
        var notRunning: [String] = []
        /// The app is running but has no window to place - a very different
        /// thing to tell someone, and the common case for browsers and editors
        /// left open with every window closed.
        var noWindow: [String] = []

        var isComplete: Bool { notRunning.isEmpty && noWindow.isEmpty }
    }

    /// Place every window of a multi-window layout, on the pane's screen.
    @discardableResult
    private func applyLayout(_ layout: WindowLayout) -> LayoutOutcome {
        guard let screen = baseScreen else { return LayoutOutcome() }
        let map = currentKeymap
        let visible = screen.adjustedVisibleFrame()
        var outcome = LayoutOutcome()
        for slot in layout.slots {
            guard !slot.appBundleId.isEmpty else { continue }
            guard let element = AccessibilityElement(slot.appBundleId)?.windowElements?.first else {
                let name = Self.displayName(forBundleId: slot.appBundleId)
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: slot.appBundleId).isEmpty
                if running {
                    if !outcome.noWindow.contains(name) { outcome.noWindow.append(name) }
                } else {
                    if !outcome.notRunning.contains(name) { outcome.notRunning.append(name) }
                }
                continue
            }
            outcome.placed.append(slot.placement)
            let rect = slot.placement.resolve(in: visible,
                                              grid: map.grid,
                                              outerMargin: map.outerMargin,
                                              innerGap: map.innerGap)
            WindowAction.specified.postPlacement(rect: rect,
                                                 screen: screen,
                                                 windowElement: element,
                                                 windowId: element.getWindowId())
            element.bringToFront()
        }
        return outcome
    }

    /// An app's name for a message, falling back to its bundle id when the app
    /// isn't installed.
    static func displayName(forBundleId bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return bundleId
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func resolveScreen(for placement: GridPlacement, base: NSScreen) -> NSScreen {
        switch placement.display {
        case .current:
            return base
        case .next:
            return ScreenDetection().detectScreens(using: targetElement)?.adjacentScreens?.next ?? base
        case .index(let i):
            let ordered = ScreenDetection().detectScreens(using: targetElement)?.screensOrdered ?? NSScreen.screens
            return (i >= 0 && i < ordered.count) ? ordered[i] : base
        }
    }

    // MARK: Timeout / teardown

    private func rearmTimeout() {
        timeoutWorkItem?.cancel()
        let seconds = max(1, Double(Defaults.placementPaneTimeout.value))
        let item = DispatchWorkItem { [weak self] in self?.endSession() }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func deactivate() {
        DispatchQueue.main.async { [weak self] in self?.endSession() }
    }

    private func endSession() {
        guard isActive || finishing || overlay != nil || monitor != nil else { return }
        setActive(false)
        setFinishing(false)
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        revealWorkItem?.cancel()
        revealWorkItem = nil
        monitor?.stop()
        monitor = nil
        overlay?.orderOut(nil)
        overlay = nil
        targetElement = nil
        targetWindowId = nil
        baseScreen = nil
    }
}
