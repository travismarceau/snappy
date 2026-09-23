/// AppDelegate.swift

import Cocoa
import ServiceManagement
import os.log

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Derived, not hard-coded: a development build has its own identifier and
    /// must talk to its own login helper, never the installed release's.
    static let launcherAppId = (Bundle.main.bundleIdentifier ?? "com.simarholonipaa.snappy") + ".Launcher"

    private let accessibilityAuthorization = AccessibilityAuthorization()
    private let statusItem = SnappyStatusItem.instance
    static let windowHistory = WindowHistory()

    private var shortcutManager: ShortcutManager!
    private var windowManager: WindowManager!
    private var applicationToggle: ApplicationToggle!
    private var windowCalculationFactory: WindowCalculationFactory!
    private var snappingManager: SnappingManager!
    private var stackBadgeManager: StackBadgeManager!
    private var placementModeManager: PlacementModeManager!
    private var titleBarManager: TitleBarManager!
    private var greenButtonManager: GreenButtonManager!
    
    private var prefsWindowController: NSWindowController?
    
    private var prevActiveAppObservation: NSKeyValueObservation?
    private var prevActiveApp: NSRunningApplication?
    private var additionalSizeMenuItems: [NSMenuItem] = []
    static let enterPlacementMenuItemTag = 7401
    private var dynamicMenuItemCount: Int = 0

    @IBOutlet weak var mainStatusMenu: NSMenu!
    @IBOutlet weak var unauthorizedMenu: NSMenu!
    @IBOutlet weak var ignoreMenuItem: NSMenuItem!
    @IBOutlet weak var viewLoggingMenuItem: NSMenuItem!
    @IBOutlet weak var quitMenuItem: NSMenuItem!
    
    static var instance: AppDelegate {
        NSApp.delegate as! AppDelegate
    }
    
    /// Runs after the main storyboard has created this delegate, but before any
    /// launch-time controller reads `Defaults`. Keep initial-scene object
    /// initializers free of `Defaults` access so migration remains first.
    func applicationWillFinishLaunching(_ notification: Notification) {
        LegacyDefaultsMigration.run()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Say plainly, every launch, whether macOS trusts us. Without this the
        // only symptom of a missing or stale grant is "the panel appears and
        // nothing happens", which is indistinguishable from a bug in the panel.
        // Recorded in defaults as well as the log: a value you can read from
        // outside the app is the difference between diagnosing this in one
        // command and guessing at it from symptoms.
        let trusted = AXIsProcessTrusted()
        UserDefaults.standard.set(trusted, forKey: "lastLaunchAccessibilityTrusted")
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "lastLaunchBundlePath")
        UserDefaults.standard.set(Date(), forKey: "lastLaunchAt")
        Logger.log("Launch: bundle=\(Bundle.main.bundleIdentifier ?? "?") path=\(Bundle.main.bundlePath) accessibilityTrusted=\(trusted)")
        Defaults.loadFromSupportDir()
        migrateShowEighthsInMenu()

        checkVersion()
        mainStatusMenu.delegate = self
        statusItem.refreshVisibility()
        checkLaunchOnLogin()
        
        let alreadyTrusted = accessibilityAuthorization.checkAccessibility {
            self.checkForConflictingApps()
            self.openPreferences(self)
            self.statusItem.statusMenu = self.mainStatusMenu
            self.accessibilityTrusted()
        }
        
        if alreadyTrusted {
            accessibilityTrusted()
        }
        
        statusItem.statusMenu = alreadyTrusted
            ? mainStatusMenu
            : unauthorizedMenu
        
        mainStatusMenu.autoenablesItems = false
        addMenuIcons()
        insertEnterPlacementMenuItem()
        // A development build has no updater: it is not what the appcast
        // describes, and letting Sparkle replace it with the released app would
        // quietly destroy the build being worked on.
        if SnappyUpdater.isEnabled { insertCheckForUpdatesMenuItem() }
        insertReportIssueMenuItem()

        // Creating the controller is what starts Sparkle's scheduler, so it has
        // to happen at launch rather than the first time Settings is opened.
        if SnappyUpdater.isEnabled { _ = SnappyUpdater.shared }

        Notification.Name.configImported.onPost(using: { _ in
            self.statusItem.refreshVisibility()
            self.applicationToggle.reloadFromDefaults()
            self.shortcutManager.reloadFromDefaults()
            self.snappingManager.reloadFromDefaults()
            self.placementModeManager?.reloadFromDefaults()
            self.initializeTodo(false)
        })
        
        Notification.Name.todoMenuToggled.onPost(using: { _ in
            self.initializeTodo(false)
        })
        
        prevActiveAppObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: .old) { workspace, change in
            self.prevActiveApp = change.oldValue ?? nil
        }
    }
    
    func checkVersion() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let lastVersion = Defaults.lastVersion.value,
           let intLastVersion = Int(lastVersion) {
            if intLastVersion < 46 {
                MASShortcutMigration.migrate()
            }
            if intLastVersion < 64 {
                SnapAreaModel.instance.migrate()
            }
            if intLastVersion < 72 {
                if #available(macOS 13, *) {
                    SMLoginItemSetEnabled(AppDelegate.launcherAppId as CFString, false)
                }
            }
        } else {
            // First run.
            Defaults.installVersion.value = currentVersion
            Defaults.allowAnyShortcut.enabled = true
        }
        MASShortcutMigration.syncRenamedSideShortcutAliases()
        
        Defaults.lastVersion.value = currentVersion
    }
    
    func applicationWillBecomeActive(_ notification: Notification) {
        Notification.Name.appWillBecomeActive.post()
    }
    
    private func addMenuIcons() {
        guard #available(macOS 11, *) else { return }
        for item in mainStatusMenu.items {
            switch item.action {
            case #selector(openPreferences):
                item.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
            case #selector(viewLogging):
                item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            default:
                break
            }
        }
    }

    func accessibilityTrusted() {
        self.windowCalculationFactory = WindowCalculationFactory()
        self.windowManager = WindowManager()
        self.shortcutManager = ShortcutManager(windowManager: windowManager)
        self.applicationToggle = ApplicationToggle(shortcutManager: shortcutManager)
        self.snappingManager = SnappingManager()
        self.stackBadgeManager = StackBadgeManager()
        self.titleBarManager = TitleBarManager()
        self.greenButtonManager = GreenButtonManager()
        self.placementModeManager = PlacementModeManager()
        self.initializeTodo()
        checkForProblematicApps()
        MacTilingDefaults.checkForBuiltInTiling(skipIfAlreadyNotified: true)
    }
    
    func checkForConflictingApps() {
        let conflictingAppsIds: [String: String] = [
            "com.divisiblebyzero.Spectacle": "Spectacle",
            "com.crowdcafe.windowmagnet": "Magnet",
            "com.hegenberg.BetterSnapTool": "BetterSnapTool",
            "com.manytricks.Moom": "Moom"
        ]
        
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }
            if let conflictingAppName = conflictingAppsIds[bundleId] {
                AlertUtil.oneButtonAlert(question: "Potential window manager conflict: \(conflictingAppName)", text: "Since \(conflictingAppName) might have some overlapping behavior with Snappy, it's recommended that you either disable or quit \(conflictingAppName).")
                break
            }
        }
        
    }
    
    /// certain applications have issues with the click listening done by the drag to snap feature
    func checkForProblematicApps() {
        guard !Defaults.windowSnapping.userDisabled, !Defaults.notifiedOfProblemApps.enabled else { return }
        
        let problemBundleIds: [String] = [
            "com.mathworks.matlab",
            "com.live2d.cubism.CECubismEditorApp",
            "com.aquafold.datastudio.DataStudio",
            "com.adobe.illustrator",
            "com.adobe.AfterEffects"
        ]
        
        // these apps are java based with dynamic bundleIds
        let problemJavaAppNames: [String] = [
            "thinkorswim",
            "Trader Workstation"
        ]

        var problemBundles: [Bundle] = problemBundleIds.compactMap { bundleId in
            if applicationToggle.isDisabled(bundleId: bundleId) { return nil }
            
            // Directly instantiating the Bundle from the bundle id didn't work for matlab for some reason
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return Bundle(url: url)
            }
            return nil
        }
        
        for name in problemJavaAppNames {
            if let path = NSWorkspace.shared.fullPath(forApplication: name) {
                if let bundle = Bundle(path: path),
                   let bundleId = bundle.bundleIdentifier {
                    
                    if !applicationToggle.isDisabled(bundleId: bundleId),
                       bundleId.starts(with: "com.install4j") {
                        problemBundles.append(bundle)
                    }
                }
            }
        }
        
        let displayNames = problemBundles.compactMap { $0.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String }
        let displayNameString = displayNames.joined(separator: "\n")
        
        if !problemBundles.isEmpty {
            AlertUtil.oneButtonAlert(question: "Known issues with installed applications", text: "\(displayNameString)\n\nThese applications have issues with the drag to screen edge to snap functionality in Snappy.\n\nYou can either ignore the applications using the menu item in Snappy, or disable drag to screen edge snapping in Snappy preferences.")
            Defaults.notifiedOfProblemApps.enabled = true
        }
    }
        
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Defaults.relaunchOpensMenu.enabled {
            statusItem.openMenu()
        } else {
            openPreferences(sender)
        }
        return true
    }
    
    /// The placement grid was reachable only by its leader shortcut, which is
    /// undiscoverable and useless if the chord is taken by another app. This
    /// puts it at the top of the status menu as well.
    private func insertEnterPlacementMenuItem() {
        let item = NSMenuItem(
            title: NSLocalizedString("Enter Placement Mode", tableName: "Main", value: "Enter Placement Mode", comment: ""),
            action: #selector(enterPlacementMode(_:)),
            keyEquivalent: "")
        item.target = self
        item.tag = AppDelegate.enterPlacementMenuItemTag
        if #available(macOS 11, *) {
            item.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)
        }
        mainStatusMenu.insertItem(item, at: 0)
        mainStatusMenu.insertItem(NSMenuItem.separator(), at: 1)
    }

    /// Snappy ships outside the App Store, so checking for updates has to be
    /// reachable without opening Settings — the status menu is the only UI a
    /// menu-bar app reliably has.
    private func insertCheckForUpdatesMenuItem() {
        guard let index = mainStatusMenu.items.firstIndex(where: { $0.action == #selector(openPreferences(_:)) })
        else { return }
        let item = NSMenuItem(
            title: NSLocalizedString("Check for Updates…", tableName: "Main", value: "Check for Updates…", comment: ""),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: "")
        item.target = self
        if #available(macOS 11, *) {
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        }
        mainStatusMenu.insertItem(item, at: index + 1)
    }

    @objc func checkForUpdates(_ sender: Any) {
        SnappyUpdater.shared.checkForUpdates()
    }

    /// "Report an Issue…", next to the update item.
    ///
    /// Holding Option copies the report instead of opening a browser, matching
    /// how "View Logging…" is already revealed, and giving anyone who would
    /// rather read what they are about to send a way to do that first.
    private func insertReportIssueMenuItem() {
        guard let index = mainStatusMenu.items.firstIndex(where: { $0.action == #selector(checkForUpdates(_:)) })
        else { return }
        let item = NSMenuItem(
            title: NSLocalizedString("Report an Issue…", tableName: "Main", value: "Report an Issue…", comment: ""),
            action: #selector(reportIssue(_:)),
            keyEquivalent: "")
        item.target = self
        if #available(macOS 11, *) {
            item.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: nil)
        }
        mainStatusMenu.insertItem(item, at: index + 1)
    }

    @objc func reportIssue(_ sender: Any) {
        if NSEvent.modifierFlags.contains(.option) {
            Diagnostics.copyToPasteboard()
            let alert = NSAlert()
            alert.messageText = "Diagnostics copied".localized
            alert.informativeText = "The report is on your clipboard. Paste it into an issue at github.com/travismarceau/snappy/issues.".localized
            alert.addButton(withTitle: "OK".localized)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else {
            Diagnostics.openIssue()
        }
    }

    /// Opens the placement grid over the frontmost window, exactly as the
    /// leader shortcut does. The status menu has already closed by the time an
    /// action fires, so the overlay's key capture starts on a clean slate.
    @objc func enterPlacementMode(_ sender: Any) {
        PlacementModeController.shared.activate()
    }

    @IBAction func openPreferences(_ sender: Any) {
        if prefsWindowController == nil {
            prefsWindowController = NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "PrefsWindowController") as? NSWindowController
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindowController?.showWindow(self)
    }
    
    @IBAction func showAbout(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Grid-based window placement built on Rectangle by Ryan Hanson (MIT License), which is itself based on Spectacle by Eric Czarny.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    
    @IBAction func viewLogging(_ sender: Any) {
        Logger.showLogging(sender: sender)
    }
    
    @IBAction func ignoreFrontMostApp(_ sender: NSMenuItem) {
        if sender.state == .on {
            applicationToggle.enableApp()
        } else {
            applicationToggle.disableApp()
        }
    }
    
    @IBAction func authorizeAccessibility(_ sender: Any) {
        accessibilityAuthorization.showAuthorizationWindow()
    }

    private func checkLaunchOnLogin() {
        if #available(macOS 13.0, *) {
            if Defaults.launchOnLogin.enabled, !LaunchOnLogin.isEnabled {
                LaunchOnLogin.isEnabled = true
            }
        } else {
            let running = NSWorkspace.shared.runningApplications
            let isRunning = !running.filter({$0.bundleIdentifier == AppDelegate.launcherAppId}).isEmpty
            if isRunning {
                let killNotification = Notification.Name("killLauncher")
                DistributedNotificationCenter.default().post(name: killNotification, object: Bundle.main.bundleIdentifier!)
            }
            if !Defaults.SUHasLaunchedBefore {
                Defaults.launchOnLogin.enabled = true
            }
            
            // Even if we are already set up to launch on login, setting it again since macOS can be buggy with this type of launch on login.
            if Defaults.launchOnLogin.enabled {
                let smLoginSuccess = SMLoginItemSetEnabled(AppDelegate.launcherAppId as CFString, true)
                if !smLoginSuccess {
                    if #available(OSX 10.12, *) {
                        os_log("Unable to enable launch at login. Attempting one more time.", type: .info)
                    }
                    SMLoginItemSetEnabled(AppDelegate.launcherAppId as CFString, true)
                }
            }
        }
    }
    
}

extension AppDelegate: NSMenuDelegate {
    
    func menuWillOpen(_ menu: NSMenu) {
        if menu != mainStatusMenu {
            updateWindowActionMenuItems(menu: menu)
            updateTodoModeMenuItems(menu: menu)
            return
        }
        
        // Offering to ignore Snappy is meaningless and still writes the bundle
        // id to disabledApps, so hide the row the way it hides with no front app.
        let frontIsSelf = ApplicationToggle.frontAppId == Bundle.main.bundleIdentifier
        if let frontAppName = ApplicationToggle.frontAppName, !frontIsSelf {
            let ignoreString = NSLocalizedString("D99-0O-MB6.title", tableName: "Main", value: "Ignore frontmost.app", comment: "")
            ignoreMenuItem.title = ignoreString.replacingOccurrences(of: "frontmost.app", with: frontAppName)
            ignoreMenuItem.state = ApplicationToggle.shortcutsDisabled ? .on : .off
            ignoreMenuItem.isHidden = false
        } else {
            ignoreMenuItem.isHidden = true
        }
        
        updateWindowActionMenuItems(menu: menu)
        updateTodoModeMenuItems(menu: menu)
        updateEnterPlacementMenuItem(menu: menu)

        viewLoggingMenuItem.keyEquivalentModifierMask = .option
        quitMenuItem.keyEquivalent = "q"
        quitMenuItem.keyEquivalentModifierMask = .command
    }
    
    /// Placement mode can be switched off, and it needs at least one region
    /// bound to have anywhere to send a window. Grey the item out rather than
    /// letting it beep.
    private func updateEnterPlacementMenuItem(menu: NSMenu) {
        guard let item = menu.item(withTag: AppDelegate.enterPlacementMenuItemTag) else { return }
        let keymap = Defaults.placementKeymap.typedValue ?? .empty
        item.isEnabled = Defaults.placementModeEnabled.userEnabled && keymap.hasAnyAssignedKey
    }

    private func updateWindowActionMenuItems(menu: NSMenu) {
        let frontmostWindow = AccessibilityElement.getFrontWindowElement()
        let screenCount = NSScreen.screens.count
        let isPortrait = NSScreen.main?.frame.isLandscape == false

        for menuItem in menu.items {
            guard let windowAction = menuItem.representedObject as? WindowAction else { continue }

            menuItem.image = windowAction.image.copy() as? NSImage
            menuItem.image?.size = NSSize(width: 18, height: 12)
            
            if isPortrait && windowAction.classification == .thirds {
                menuItem.image = menuItem.image?.rotated(by: 270)
                menuItem.image?.isTemplate = true
            }

            if !ApplicationToggle.shortcutsDisabled {
                if let fullKeyEquivalent = shortcutManager.getKeyEquivalent(action: windowAction),
                    let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
                    menuItem.keyEquivalent = keyEquivalent
                    menuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
                }
            }
            if frontmostWindow == nil {
                menuItem.isEnabled = false
            }
            if windowAction == .nextDisplay || windowAction == .previousDisplay {
                menuItem.isHidden = screenCount == 1 || Defaults.combinedDisplayMode.userEnabled
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        for menuItem in menu.items {
            
            menuItem.keyEquivalent = ""
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags()
            
            menuItem.isEnabled = true
        }
    }
    
    @objc func executeMenuWindowAction(sender: NSMenuItem) {
        guard let windowAction = sender.representedObject as? WindowAction else { return }
        windowAction.postMenu()
    }
    
    func addWindowActionMenuItems() {
        let additionalSizeCategories: Set<WindowActionCategory> = [.eighths, .ninths, .twelfths, .sixteenths]
        let submenuOnlyWhenAdditional: Set<WindowActionCategory> = [.thirds, .size]
        let showAdditional = Defaults.showAdditionalSizesInMenu.userEnabled
        var menuIndex = 0
        var categoryMenus: [CategoryMenu] = []
        for action in WindowAction.active {
            guard let displayName = action.displayName else { continue }
            let newMenuItem = NSMenuItem(title: displayName, action: #selector(executeMenuWindowAction), keyEquivalent: "")
            newMenuItem.representedObject = action

            if !Defaults.showAllActionsInMenu.userEnabled, let category = action.category {
                // When additional sizes are off, keep Thirds and Size as flat items
                if submenuOnlyWhenAdditional.contains(category) && !showAdditional {
                    // Fall through to flat item handling below
                } else {
                    if menuIndex != 0 && action.firstInGroup {
                        let menu = NSMenu(title: category.displayName)
                        menu.autoenablesItems = false
                        categoryMenus.append(CategoryMenu(menu: menu, category: category))
                    }
                    categoryMenus.last?.menu.addItem(newMenuItem)
                    continue
                }
            }

            // Flat item - suppress extra separator for almostMaximize when Size is not a submenu
            let showSeparator = action.firstInGroup && !(action == .almostMaximize && !showAdditional)
            if menuIndex != 0 && showSeparator {
                mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)
                menuIndex += 1
            }
            mainStatusMenu.insertItem(newMenuItem, at: menuIndex)
            menuIndex += 1
        }

        if !categoryMenus.isEmpty {
            mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)
            menuIndex += 1

            let sortedCategoryMenus = categoryMenus.sorted { $0.category.menuOrder < $1.category.menuOrder }
            for categoryMenu in sortedCategoryMenus {
                categoryMenu.menu.delegate = self
                let menuMenuItem = NSMenuItem(title: categoryMenu.category.displayName, action: nil, keyEquivalent: "")
                if additionalSizeCategories.contains(categoryMenu.category) {
                    menuMenuItem.isHidden = !Defaults.showAdditionalSizesInMenu.userEnabled
                    additionalSizeMenuItems.append(menuMenuItem)
                }
                mainStatusMenu.insertItem(menuMenuItem, at: menuIndex)
                mainStatusMenu.setSubmenu(categoryMenu.menu, for: menuMenuItem)
                menuIndex += 1
            }
        }

        mainStatusMenu.insertItem(NSMenuItem.separator(), at: menuIndex)

        menuIndex += 1
        addTodoModeMenuItems(startingIndex: menuIndex)
        // Track total dynamic items: window actions + separators + todo items (4 items + 1 separator)
        dynamicMenuItemCount = menuIndex + 5
    }

    @objc func rebuildMenu() {
        // Snappy no longer lists window actions in the status menu.
        dynamicMenuItemCount = 0
        additionalSizeMenuItems.removeAll()
    }

    private func migrateShowEighthsInMenu() {
        let oldKey = "showEighthsInMenu"
        let oldValue = UserDefaults.standard.integer(forKey: oldKey)
        if oldValue != 0 && Defaults.showAdditionalSizesInMenu.notSet {
            Defaults.showAdditionalSizesInMenu.enabled = (oldValue == 1)
        }
    }

    struct CategoryMenu {
        let menu: NSMenu
        let category: WindowActionCategory
    }

}

// todo mode
extension AppDelegate {
    func initializeTodo(_ bringToFront: Bool = true) {
        self.showHideTodoMenuItems()
        TodoManager.registerUnregisterToggleShortcut()
        TodoManager.registerUnregisterReflowShortcut()
        TodoManager.moveAllIfNeeded(bringToFront)
    }

    enum TodoItem {
        case mode, app, reflow, separator, window

        var tag: Int {
            switch self {
            case .mode: return 101
            case .app: return 102
            case .reflow: return 103
            case .separator: return 104
            case .window: return 105
            }
        }
        
        static let tags = [101, 102, 103, 104, 105]
    }

    private func addTodoModeMenuItems(startingIndex: Int) {
        var menuIndex = startingIndex

        let todoModeItemTitle = NSLocalizedString("Enable Todo Mode", tableName: "Main", value: "", comment: "")
        let todoModeMenuItem = NSMenuItem(title: todoModeItemTitle, action: #selector(toggleTodoMode), keyEquivalent: "")
        todoModeMenuItem.tag = TodoItem.mode.tag
        todoModeMenuItem.target = self
        mainStatusMenu.insertItem(todoModeMenuItem, at: menuIndex)
        menuIndex += 1

        let todoAppItemTitle = NSLocalizedString("Use frontmost.app as Todo App", tableName: "Main", value: "", comment: "")
        let todoAppMenuItem = NSMenuItem(title: todoAppItemTitle, action: #selector(setTodoApp), keyEquivalent: "")
        todoAppMenuItem.tag = TodoItem.app.tag
        mainStatusMenu.insertItem(todoAppMenuItem, at: menuIndex)
        menuIndex += 1

        let todoWindowItemTitle = NSLocalizedString("Use as Todo Window", tableName: "Main", value: "", comment: "")
        let todoWindowMenuItem = NSMenuItem(title: todoWindowItemTitle, action: #selector(setTodoWindow), keyEquivalent: "")
        todoWindowMenuItem.tag = TodoItem.window.tag
        mainStatusMenu.insertItem(todoWindowMenuItem, at: menuIndex)
        menuIndex += 1
        
        let todoReflowItemTitle = NSLocalizedString("Reflow Todo", tableName: "Main", value: "", comment: "")
        let todoReflowItem = NSMenuItem(title: todoReflowItemTitle, action: #selector(todoReflow), keyEquivalent: "")
        todoReflowItem.tag = TodoItem.reflow.tag
        mainStatusMenu.insertItem(todoReflowItem, at: menuIndex)
        menuIndex += 1
        
        let separator = NSMenuItem.separator()
        separator.tag = TodoItem.separator.tag
        mainStatusMenu.insertItem(separator, at: menuIndex)
        
        showHideTodoMenuItems()
    }
    
    private func showHideTodoMenuItems() {
        for item in mainStatusMenu.items {
            if TodoItem.tags.contains(item.tag) {
                item.isHidden = !Defaults.todo.userEnabled
            }
        }
    }

    @objc func toggleTodoMode(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        TodoManager.setTodoMode(enabled)
    }

    @objc func setTodoApp(_ sender: NSMenuItem) {
        applicationToggle.setTodoApp()
        TodoManager.moveAllIfNeeded()
    }

    @objc func todoReflow(_ sender: NSMenuItem) {
        TodoManager.moveAll()
    }
    
    @objc func setTodoWindow(_ sender: NSMenuItem) {
        TodoManager.resetTodoWindow()
        TodoManager.moveAllIfNeeded()
    }

    private func updateTodoModeMenuItems(menu: NSMenu) {
        guard Defaults.todo.userEnabled,
              let todoAppMenuItem = menu.item(withTag: TodoItem.app.tag),
              let todoModeMenuItem = menu.item(withTag: TodoItem.mode.tag),
              let todoReflowMenuItem = menu.item(withTag: TodoItem.reflow.tag),
              let todoWindowMenuItem = menu.item(withTag: TodoItem.window.tag)
        else {
            return
        }

        // Offering to ignore Snappy is meaningless and still writes the bundle
        // id to disabledApps, so hide the row the way it hides with no front app.
        let frontIsSelf = ApplicationToggle.frontAppId == Bundle.main.bundleIdentifier
        if let frontAppName = ApplicationToggle.frontAppName, !frontIsSelf {
            let appString = NSLocalizedString("Use frontmost.app as Todo App", tableName: "Main", value: "", comment: "")
            todoAppMenuItem.title = appString.replacingOccurrences(
                of: "frontmost.app", with: frontAppName)
            todoAppMenuItem.isEnabled = !applicationToggle.todoAppIsActive()
            todoAppMenuItem.state = applicationToggle.todoAppIsActive() ? .on : .off
            todoAppMenuItem.isHidden = false
        } else {
            todoAppMenuItem.isHidden = true
        }

        todoModeMenuItem.state = Defaults.todoMode.enabled ? .on : .off
        
        if let fullKeyEquivalent = TodoManager.getToggleKeyDisplay(),
            let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
            todoModeMenuItem.keyEquivalent = keyEquivalent
            todoModeMenuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
        }

        if let fullKeyEquivalent = TodoManager.getReflowKeyDisplay(),
            let keyEquivalent = fullKeyEquivalent.0?.lowercased() {
            todoReflowMenuItem.keyEquivalent = keyEquivalent
            todoReflowMenuItem.keyEquivalentModifierMask = fullKeyEquivalent.1
        }
        
        todoReflowMenuItem.isEnabled = Defaults.todoMode.enabled
        
        todoWindowMenuItem.isHidden = !applicationToggle.todoAppIsActive() || TodoManager.isTodoWindowFront()
    }
}

extension AppDelegate: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        NSApp.abortModal()
    }
    
}

extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if NSWorkspace.shared.frontmostApplication == NSRunningApplication.current {
            prevActiveApp?.activate()
        }
        DispatchQueue.main.async {
            
            func getUrlName(_ name: String) -> String {
                return name.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined()
            }
            
            func extractBundleIdParameter(fromComponents components: URLComponents) -> String? {
                (components.queryItems?.first { $0.name == "app-bundle-id" })?.value ?? ApplicationToggle.frontAppId
            }
            
            func isValidParameter(bundleId: String?) -> Bool {
                let isValid = bundleId?.isEmpty != true
                if !isValid {
                    Logger.log("Received an empty app-bundle-id parameter. Either pass a valid app bundle id or remove the parameter.")
                }
                return isValid
            }
            
            func confirmExecuteTask(action: String, bundleId: String) -> Bool {
                // Defense-in-depth: any web page or another app can trigger the
                // `snappy://execute-task=ignore-app` URL with an arbitrary
                // bundle-id. Without confirmation this silently mutates
                // Snappy's `disabledApps` defaults. Skip the prompt only
                // when Snappy itself is frontmost (i.e. the user almost
                // certainly clicked this from inside Snappy's own UI).
                if NSWorkspace.shared.frontmostApplication == NSRunningApplication.current {
                    return true
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Allow Snappy URL action?".localized
                alert.informativeText = String(format: "An external source asked Snappy to perform \"%@\" on app bundle id \"%@\". Allow?".localized, action, bundleId)
                alert.addButton(withTitle: "Allow".localized)
                alert.addButton(withTitle: "Cancel".localized)
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }
            
            for url in urls {
                guard
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                    components.path.isEmpty
                else {
                    continue
                }
                    
                let name = (components.queryItems?.first { $0.name == "name" })?.value
                switch (components.host, name) {
                case ("execute-action", _):
                    let action = (WindowAction.active.first { windowAction in
                        if let aliasName = windowAction.aliasName, getUrlName(aliasName) == name {
                            return true
                        }
                        return getUrlName(windowAction.name) == name
                    })
                    action?.postUrl()
                case ("execute-task", "copy-diagnostics"):
                    // Support without a screen-share: "run this, paste what it
                    // copies". Also the only way to exercise the report in a
                    // test, since the menu needs a person.
                    Diagnostics.copyToPasteboard()
                case ("execute-task", "enter-placement"):
                    // Opens the placement panel exactly as the leader shortcut
                    // does. Anything a person can reach from the menu bar should
                    // be reachable without a keyboard -- for scripting, for
                    // automation, and so the panel can be exercised in a test
                    // without synthesising a global hotkey.
                    PlacementModeController.shared.activate()
                case ("execute-task", "ignore-app"):
                    let bundleId = extractBundleIdParameter(fromComponents: components)
                    guard isValidParameter(bundleId: bundleId), let bundleId else { continue }
                    guard confirmExecuteTask(action: "ignore-app", bundleId: bundleId) else { continue }
                    self.applicationToggle.disableApp(appBundleId: bundleId)
                case ("execute-task", "unignore-app"):
                    let bundleId = extractBundleIdParameter(fromComponents: components)
                    guard isValidParameter(bundleId: bundleId), let bundleId else { continue }
                    guard confirmExecuteTask(action: "unignore-app", bundleId: bundleId) else { continue }
                    self.applicationToggle.enableApp(appBundleId: bundleId)
                default:
                    continue
                }
            }
        }
    }
}
