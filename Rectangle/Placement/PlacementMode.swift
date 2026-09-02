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

    /// Guards `active` and `keymap`, both of which the event-tap thread reads
    /// from `shouldSwallow` while the main thread mutates them.
    private let stateLock = NSLock()
    private var active = false
    private var keymap = PlacementKeymap.empty

    private var monitor: ActiveEventMonitor?
    private var overlay: PlacementOverlayPanel?
    private var timeoutWorkItem: DispatchWorkItem?

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

    // MARK: Activation

    func activate() {
        DispatchQueue.main.async { [weak self] in self?.beginSession() }
    }

    private func beginSession() {
        if isActive { rearmTimeout(); return }
        guard Defaults.placementModeEnabled.userEnabled else { return }

        let map = Defaults.placementKeymap.typedValue ?? .empty
        guard !map.assignedBindings.isEmpty else {
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

        let panel = PlacementOverlayPanel(screen: screen, keymap: map)
        panel.orderFrontRegardless()
        overlay = panel

        let monitor = ActiveEventMonitor(
            mask: [.keyDown],
            filterer: { [weak self] event in self?.shouldSwallow(event) ?? false },
            handler: { [weak self] event in self?.handleKey(event) }
        )
        monitor.start()
        self.monitor = monitor

        setActive(true)
        rearmTimeout()
    }

    // MARK: Event handling

    /// Runs on the event-tap thread. Returning true consumes the event so it
    /// never reaches the focused app.
    private func shouldSwallow(_ event: NSEvent) -> Bool {
        guard isActive, event.type == .keyDown else { return false }
        if Int(event.keyCode) == kVK_Escape { return true }
        let mods = event.modifierFlags.rawValue & placementModifierMask
        if currentKeymap.binding(forKeyCode: Int(event.keyCode), modifierFlags: mods) != nil { return true }
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
        guard let binding = currentKeymap.binding(forKeyCode: keyCode, modifierFlags: mods) else {
            NSSound.beep()
            rearmTimeout()
            return
        }

        place(binding)

        if Defaults.placementPaneSticky.enabled {
            // The user will focus a different window before the next key.
            targetElement = AccessibilityElement.getFrontWindowElement()
            targetWindowId = targetElement?.getWindowId()
            overlay?.flash(binding)
            rearmTimeout()
        } else {
            deactivate()
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
        guard isActive || overlay != nil || monitor != nil else { return }
        setActive(false)
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        monitor?.stop()
        monitor = nil
        overlay?.orderOut(nil)
        overlay = nil
        targetElement = nil
        targetWindowId = nil
        baseScreen = nil
    }
}
