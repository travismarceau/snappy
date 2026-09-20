/// PlacementMode.swift
///
/// The "leader key" runtime for Divvy-style window placement:
///   1. `PlacementModeManager` owns a single global shortcut (via MASShortcut,
///      like `TodoManager`) that toggles placement mode on.
///   2. `PlacementModeController` shows the on-screen grid pane — one per
///      display — and captures input with an `ActiveEventMonitor`. A key
///      resolves through the saved `PlacementKeymap`; a mouse drag draws a
///      region that was never saved at all. Either way the rect goes to the
///      normal execution pipeline through
///      `WindowAction.specified.postPlacement(...)`.

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
        // The keymap, the grid or the drag setting may have just changed, and a
        // cached pane still draws the old one.
        PlacementModeController.shared.invalidatePanelCache()
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

// MARK: - Controller (modal panes + input capture)

final class PlacementModeController {

    static let shared = PlacementModeController()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    /// How long a session may live with its timeout cancelled by an in-flight
    /// drag. The session swallows mouse clicks system-wide, so it must not be
    /// able to outlive a gesture that never ends — a mouse unplugged mid-drag,
    /// say, or a tap that stops delivering.
    private static let hardStopSeconds: TimeInterval = 30
    /// How long an unused pane is kept warm. Long enough to cover placing
    /// several windows in a row, short enough that a menu-bar app is not
    /// sitting on a full-screen backing store all day.
    private static let panelCacheSeconds: TimeInterval = 60

    /// Guards the state the event-tap thread reads from `shouldSwallow` while
    /// the main thread mutates it. Everything behind it is a value type: the
    /// tap thread never touches AppKit.
    /// Diagnostics for the event tap, read back from defaults after a session.
    private static var tapEventsSeen = 0
    private static var tapEventsSwallowed = 0

    private let stateLock = NSLock()
    private var active = false
    private var keymap = PlacementKeymap.empty
    /// True during the brief flash between a placement and teardown, so the
    /// event tap keeps swallowing keys even though `active` is already false.
    private var _finishing = false
    private var _dragEnabled = false
    private var _dragging = false

    private var monitor: ActiveEventMonitor?
    private var overlays: [PlacementOverlayPanel] = []
    /// Panes kept warm between sessions; building one allocates a full-screen
    /// backing store, which is far too much work for a keystroke.
    private var cachedPanels: [PlacementOverlayPanel] = []
    private var cacheReleaseWorkItem: DispatchWorkItem?

    private var timeoutWorkItem: DispatchWorkItem?
    private var revealWorkItem: DispatchWorkItem?
    private var hardStopWorkItem: DispatchWorkItem?

    private var targetElement: AccessibilityElement?
    private var targetWindowId: CGWindowID?
    private var baseScreen: NSScreen?

    // The in-flight drag. `dragPanel` owns the gesture: a drag that starts on
    // one display stays on it, however far the cursor wanders.
    private var dragPanel: PlacementOverlayPanel?
    private var dragAnchor: GridCell?
    private var dragSelection: GridPlacement?
    private var hoverPanel: PlacementOverlayPanel?
    private var hoverCell: GridCell?

    // MARK: Locked state accessors

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
    private var dragEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _dragEnabled
    }
    private func setDragEnabled(_ value: Bool) {
        stateLock.lock(); _dragEnabled = value; stateLock.unlock()
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
        let dragEnabled = !Defaults.placementDragEnabled.userDisabled
        // With dragging on there is always something to do, even with an empty
        // keymap. Without it, a pane with no bound keys is a dead end.
        guard map.hasAnyAssignedKey || dragEnabled else {
            NSSound.beep()
            return
        }
        setKeymap(map)

        let panels = preparePanels(keymap: map, dragEnabled: dragEnabled)
        guard !panels.isEmpty else {
            NSSound.beep()
            return
        }
        overlays = panels
        setDragEnabled(dragEnabled)
        // Secure Event Input blocks every keyboard event tap on the system, and
        // nothing else: the mouse is untouched. So the panel opens, dragging
        // places windows perfectly, and bound keys do nothing at all while
        // typing straight through to the app behind -- with every permission
        // correctly granted and nothing anywhere to say why.
        //
        // It is usually left stuck by a password field or a lock screen, and the
        // owner is often reported as loginwindow rather than whichever app asked
        // for it. Locking and unlocking the Mac clears it, which is why that has
        // always been the first line of this app's troubleshooting advice.
        let secureInput = IsSecureEventInputEnabled()
        let blocker = secureInput ? PlacementModeController.secureInputHolderName() : nil
        UserDefaults.standard.set(secureInput, forKey: "lastSessionSecureInputEnabled")
        if secureInput {
            UserDefaults.standard.set(blocker ?? "unknown", forKey: "lastSessionSecureInputHolder")
            Logger.log("Secure Event Input is enabled, held by \(blocker ?? "an unknown process") — no keyboard event tap can receive keys. Bound keys will not work until it is cleared (lock and unlock the Mac).")
        }

        if secureInput {
            // The reported owner is whichever app is frontmost at the time, so
            // it names a suspect rather than a culprit: a terminal with secure
            // keyboard entry on is a common cause, but so is a state left
            // latched after a password prompt, in which case the pid just
            // follows focus around. Say what is happening and give the remedy
            // that works either way.
            let message = "Secure Input is on — bound keys cannot work. Log out or restart to clear it."
            panels.forEach { $0.setWarning(message) }
        }
        panels.forEach { $0.present() }

        let monitor = ActiveEventMonitor(
            // Keys only. The panel is a real window now and takes its own mouse
            // events, so dragging no longer depends on a tap -- which needs
            // Accessibility and silently does nothing without it.
            mask: [.keyDown],
            filterer: { [weak self] event in self?.shouldSwallow(event) ?? false },
            handler: { [weak self] event in self?.handleEvent(event) }
        )
        monitor.start()
        self.monitor = monitor
        // The single most common failure: no Accessibility grant means no event
        // tap, which looks like "the panel is up but my keys go to the app
        // behind it". Say so rather than leaving it to be inferred.
        // Also recorded in defaults: os_log from a background-only app is
        // awkward to read back, and this is the one fact that separates "the
        // panel is broken" from "macOS will not give us an event tap".
        Self.tapEventsSeen = 0
        Self.tapEventsSwallowed = 0
        EventTapDiagnostics.callbackInvocations = 0
        EventTapDiagnostics.disableNotices = 0
        UserDefaults.standard.set(monitor.running, forKey: "lastSessionEventTapRunning")
        UserDefaults.standard.set(Date(), forKey: "lastSessionAt")
        if !monitor.running {
            Logger.log("Placement mode: event tap NOT running — keystrokes will reach the app behind the panel. Accessibility grant missing or stale for \(Bundle.main.bundleIdentifier ?? "?").")
        } else {
            Logger.log("Placement mode: event tap running, keys captured.")
        }

        setActive(true)
        scheduleMapReveal()
        rearmTimeout()

        // The panes are already on screen by the time this runs. Capturing the
        // target window is a synchronous accessibility round-trip that can block
        // for as long as the focused app takes to answer, and there is no reason
        // for the overlay to wait on it. Nothing can steal focus in between: the
        // panes are non-activating and the tap swallows input.
        DispatchQueue.main.async { [weak self] in self?.captureTarget() }
    }

    /// Resolve the window a keystroke or drag will move, and the display the
    /// keyboard path treats as "current".
    private func captureTarget() {
        guard isActive else { return }
        targetElement = AccessibilityElement.getFrontWindowElement()
        targetWindowId = targetElement?.getWindowId()

        let usable = Defaults.useCursorScreenDetection.enabled
            ? ScreenDetection().detectScreensAtCursor()
            : ScreenDetection().detectScreens(using: targetElement)
        baseScreen = usable?.currentScreen ?? NSScreen.main

        // Title the panel with the window it is about to move. A bare grid gives
        // no clue which of several windows is the target.
        let app = NSWorkspace.shared.frontmostApplication
        overlays.forEach { $0.setTarget(name: app?.localizedName, icon: app?.icon) }
    }

    // MARK: Panes

    /// One pane per display, reusing a warm one wherever it still matches. The
    /// frame is `adjustedVisibleFrame` — the rect placements actually resolve
    /// against — so the grid is painted exactly where the windows will land,
    /// Todo sidebar and Stage Manager strip included.
    private func preparePanels(keymap: PlacementKeymap, dragEnabled: Bool) -> [PlacementOverlayPanel] {
        cacheReleaseWorkItem?.cancel()
        cacheReleaseWorkItem = nil

        var reusable = cachedPanels
        cachedPanels = []

        // One panel, on the display being placed onto. The full-screen version
        // needed one per display because it covered them; a small box does not.
        let screen = Defaults.useCursorScreenDetection.enabled
            ? (ScreenDetection().detectScreensAtCursor()?.currentScreen ?? NSScreen.main)
            : NSScreen.main
        guard let screen else { return [] }
        let frame = screen.adjustedVisibleFrame()
        guard frame.width > 1, frame.height > 1 else { return [] }

        let panel: PlacementOverlayPanel
        if let i = reusable.firstIndex(where: { $0.matches(frame: frame, keymap: keymap, dragEnabled: dragEnabled) }) {
            panel = reusable.remove(at: i)
            panel.prepareForReuse()
        } else {
            panel = PlacementOverlayPanel(screen: screen, frame: frame, keymap: keymap, dragEnabled: dragEnabled)
        }
        reusable.forEach { $0.orderOut(nil) }

        panel.onDragChanged = { [weak self] p in self?.dragSelection = p }
        panel.onDragCommitted = { [weak self] p in self?.commitDrag(p, on: panel) }
        return [panel]
    }

    /// Hold the panes for a short while: placing several windows in a row is the
    /// common case, and rebuilding them per keystroke is the expensive one. They
    /// are ordered out by the fade that follows, not here.
    private func parkPanels(_ panels: [PlacementOverlayPanel]) {
        cachedPanels = panels

        cacheReleaseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cachedPanels.forEach { $0.orderOut(nil) }
            self.cachedPanels = []
            self.cacheReleaseWorkItem = nil
        }
        cacheReleaseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelCacheSeconds, execute: item)
    }

    /// Drop warm panes whose grid, keymap or geometry is no longer current.
    func invalidatePanelCache() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cacheReleaseWorkItem?.cancel()
            self.cacheReleaseWorkItem = nil
            self.cachedPanels.forEach { $0.orderOut(nil) }
            self.cachedPanels = []
        }
    }

    @objc private func screenParametersChanged() {
        endSession()
        invalidatePanelCache()
    }

    private func scheduleMapReveal() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
        switch Defaults.placementMapReveal.value {
        case .always:
            overlays.forEach { $0.revealPlacements(animated: false) }
        case .never:
            break
        case .afterDelay:
            let delay = max(0.05, Double(Defaults.placementMapRevealDelay.value))
            let item = DispatchWorkItem { [weak self] in
                self?.overlays.forEach { $0.revealPlacements(animated: true) }
            }
            revealWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: Event filtering

    /// Runs on the event-tap thread. Returning true consumes the event so it
    /// never reaches the focused app.
    private func shouldSwallow(_ event: NSEvent) -> Bool {
        // Counted so a session can be asked afterwards whether the tap ever saw
        // anything. "The tap exists" and "the tap receives events" are different
        // claims, and only the second one matters.
        Self.tapEventsSeen += 1
        guard isActive || finishing else { return false }

        switch event.type {
        case .keyDown:
            guard isActive else { return true } // in the flash tail: swallow everything, act on nothing
            if Int(event.keyCode) == kVK_Escape { return true }
            let mods = event.modifierFlags.rawValue & placementModifierMask
            let code = Int(event.keyCode)
            if currentKeymap.binding(forKeyCode: code, modifierFlags: mods) != nil { Self.tapEventsSwallowed += 1; return true }
            if currentKeymap.layout(forKeyCode: code, modifierFlags: mods) != nil { Self.tapEventsSwallowed += 1; return true }
            // Bare keystrokes are the "any single key" the user means to capture;
            // swallow them. Unrecognised modified combos (⌘Tab, ⌘Q…) pass through so
            // the user can still switch or quit apps, useful in sticky mode.
            if mods == 0 { Self.tapEventsSwallowed += 1; return true }
            return false

        default:
            return false
        }
    }

    // MARK: Event handling

    /// Dispatched to the main thread by `ActiveEventMonitor`.
    private func handleEvent(_ event: NSEvent) {
        guard isActive else { return }
        guard event.type == .keyDown else { return }
        handleKey(event)
    }

    private func handleKey(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            // Escape backs out of a drag first, and only then out of the pane.
            if dragSelection != nil {
                cancelDrag()
            } else {
                deactivate()
            }
            return
        }
        let mods = event.modifierFlags.rawValue & placementModifierMask

        if let binding = currentKeymap.binding(forKeyCode: keyCode, modifierFlags: mods) {
            revealWorkItem?.cancel()
            cancelDrag(rearmingTimeout: false)
            let screen = resolveScreen(for: binding.placement, base: baseScreen)
            panel(for: screen)?.flash(placement: binding.placement)
            place(binding.placement, on: screen, element: targetElement, windowId: targetWindowId)
            finishPlacement()
        } else if let layout = currentKeymap.layout(forKeyCode: keyCode, modifierFlags: mods) {
            revealWorkItem?.cancel()
            cancelDrag(rearmingTimeout: false)
            let outcome = applyLayout(layout)
            panel(for: baseScreen)?.flash(layout: layout, outcome: outcome)
            finishPlacement(holdingFor: outcome.isComplete ? 0.24 : 1.5)
        } else {
            NSSound.beep()
            // An unrecognised key almost always means "I forget my map" — show it.
            revealWorkItem?.cancel()
            overlays.forEach { $0.revealPlacements(animated: true) }
            rearmTimeout()
        }
    }

    // MARK: Mouse

    private func panel(for screen: NSScreen?) -> PlacementOverlayPanel? {
        guard let screen else { return nil }
        return overlays.first { $0.targetScreen == screen }
    }

    /// The panel reports a finished drag. Release is terminal: place and get out
    /// of the way -- you watched the rectangle the whole way down, so there is
    /// nothing left to confirm and no flash worth waiting through.
    private func commitDrag(_ placement: GridPlacement, on panel: PlacementOverlayPanel) {
        guard isActive else { return }
        dragSelection = nil
        place(placement, on: panel.targetScreen, element: targetElement, windowId: targetWindowId)
        endSession()
    }

    private func cancelDrag(rearmingTimeout: Bool = true) {
        dragSelection = nil
        overlays.forEach { $0.clearDrag() }
        if rearmingTimeout { rearmTimeout() }
    }

    // MARK: Placement

    /// Shared sticky-vs-dismiss tail after a *key* resolves to a placement or
    /// layout. `holdingFor` is how long the flash stays up before teardown -
    /// longer when there is a message to read. The drag path does not come
    /// through here: it has no flash to wait on.
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

    private func place(_ placement: GridPlacement,
                       on screen: NSScreen,
                       element: AccessibilityElement?,
                       windowId: CGWindowID?) {
        let map = currentKeymap
        let rect = placement.resolve(
            in: screen.adjustedVisibleFrame(),
            grid: map.grid,
            outerMargin: map.outerMargin,
            innerGap: map.innerGap
        )
        WindowAction.specified.postPlacement(
            rect: rect,
            screen: screen,
            windowElement: element,
            windowId: windowId
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
        guard let screen = baseScreen ?? NSScreen.main else { return LayoutOutcome() }
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
            place(slot.placement, on: screen, element: element, windowId: element.getWindowId())
            element.bringToFront()
        }
        return outcome
    }

    /// The app currently holding Secure Event Input, if any.
    ///
    /// macOS publishes the owning pid in the session dictionary but surfaces it
    /// nowhere a user would look, so an app that enables Secure Input and never
    /// releases it breaks every keyboard event tap on the system with no
    /// attribution at all.
    static func secureInputHolderName() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              // NSNumber does not bridge straight to pid_t here; going through
              // NSNumber is what actually reads the value.
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              pid > 0
        else { return nil }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        }
        return "pid \(pid)"
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

    private func resolveScreen(for placement: GridPlacement, base: NSScreen?) -> NSScreen {
        let fallback = base ?? NSScreen.main ?? NSScreen.screens[0]
        switch placement.display {
        case .current:
            return fallback
        case .next:
            return ScreenDetection().detectScreens(using: targetElement)?.adjacentScreens?.next ?? fallback
        case .index(let i):
            let ordered = ScreenDetection().detectScreens(using: targetElement)?.screensOrdered ?? NSScreen.screens
            return (i >= 0 && i < ordered.count) ? ordered[i] : fallback
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

    /// A ceiling on an in-flight drag, armed only while one is running.
    ///
    /// A drag cancels the idle timeout — it must not expire mid-gesture — and
    /// for as long as it runs the session is swallowing clicks system-wide. So
    /// "the mouse-up never arrives" (a mouse unplugged mid-drag, a tap that
    /// stops delivering) has to resolve to teardown rather than to a dead
    /// cursor. Deliberately not armed for the session as a whole: sticky mode
    /// keeps a pane up across many placements, and each one rearms the ordinary
    /// timeout, which is what bounds that case.
    private func armHardStop() {
        hardStopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Logger.log("Placement mode drag never completed; tearing down")
            self?.endSession()
        }
        hardStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hardStopSeconds, execute: item)
    }

    func deactivate() {
        DispatchQueue.main.async { [weak self] in self?.endSession() }
    }

    private func endSession() {
        guard isActive || finishing || !overlays.isEmpty || monitor != nil else { return }
        setActive(false)
        setFinishing(false)
        setDragEnabled(false)

        UserDefaults.standard.set(EventTapDiagnostics.callbackInvocations, forKey: "lastSessionTapCallbacks")
        UserDefaults.standard.set(EventTapDiagnostics.disableNotices, forKey: "lastSessionTapDisables")
        UserDefaults.standard.set(Self.tapEventsSeen, forKey: "lastSessionTapEventsSeen")
        UserDefaults.standard.set(Self.tapEventsSwallowed, forKey: "lastSessionTapEventsSwallowed")
        timeoutWorkItem?.cancel(); timeoutWorkItem = nil
        revealWorkItem?.cancel(); revealWorkItem = nil
        hardStopWorkItem?.cancel(); hardStopWorkItem = nil

        // Stop swallowing input before anything slower happens.
        monitor?.stop()
        monitor = nil

        dragPanel = nil
        dragAnchor = nil
        dragSelection = nil
        hoverPanel = nil
        hoverCell = nil
        targetElement = nil
        targetWindowId = nil
        baseScreen = nil

        let panels = overlays
        overlays = []
        guard !panels.isEmpty else { return }
        // Fade out rather than cut, so the window is seen landing under the
        // dissolving grid.
        parkPanels(panels)
        panels.forEach { panel in
            panel.dismiss { [weak self] in
                // A new session may have claimed this pane back mid-fade.
                guard self?.overlays.contains(where: { $0 === panel }) != true else { return }
                panel.orderOut(nil)
            }
        }
    }
}
