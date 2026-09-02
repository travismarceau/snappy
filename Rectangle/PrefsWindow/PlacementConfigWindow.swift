/// PlacementConfigWindow.swift
///
/// The Divvy-style configuration UI: pick a grid size, then for each key draw a
/// rectangular region on the grid and assign a single keystroke to it. Opened
/// from the status menu ("Configure Window Placements…"). Standalone,
/// programmatic AppKit — no storyboard scene.

import Cocoa
import MASShortcut

// MARK: - Window controller

final class PlacementConfigWindowController: NSWindowController {

    static let shared = PlacementConfigWindowController()

    private convenience init() {
        let vc = PlacementConfigViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = NSLocalizedString("Window Placement", tableName: "Main", value: "Window Placement", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 580))
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(self)
        window?.makeKeyAndOrderFront(self)
    }
}

// MARK: - View controller

final class PlacementConfigViewController: NSViewController {

    private var keymap = Defaults.placementKeymap.typedValue ?? .empty {
        didSet { Defaults.placementKeymap.typedValue = keymap }
    }

    private let recordingObserver = ShortcutRecordingObserver()

    private let tableView = NSTableView()
    private let picker = PlacementGridPickerView()
    private let keyCaptureButton = KeyCaptureButton()
    private let labelField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let conflictLabel = NSTextField(labelWithString: "")
    private let rowsField = NSTextField()
    private let colsField = NSTextField()
    private let outerMarginField = NSTextField()
    private let innerGapField = NSTextField()
    private let stickyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let enableCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    private var selectedIndex: Int? {
        tableView.selectedRow >= 0 ? tableView.selectedRow : nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        syncControlsFromModel()
        reloadTable()
        selectRow(keymap.bindings.isEmpty ? nil : 0)
    }

    // MARK: Layout

    private func buildLayout() {
        // Top: enable + leader shortcut
        enableCheckbox.title = NSLocalizedString("Enable Window Placement Mode", tableName: "Main", value: "Enable Window Placement Mode", comment: "")
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleEnabled)

        let leaderLabel = NSTextField(labelWithString: NSLocalizedString("Placement Mode shortcut:", tableName: "Main", value: "Placement Mode shortcut:", comment: ""))
        let leaderShortcutView = MASShortcutView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
        leaderShortcutView.shortcutValidator = AppShortcutValidator(defaultsKey: PlacementModeManager.defaultsKey)
        leaderShortcutView.setAssociatedUserDefaultsKey(PlacementModeManager.defaultsKey, withTransformerName: MASDictionaryTransformerName)
        recordingObserver.observe([leaderShortcutView])
        PlacementModeManager.initShortcut()

        let topRow = row([enableCheckbox, spacer(), leaderLabel, leaderShortcutView])

        // Grid + margins row
        configureNumberField(rowsField, action: #selector(gridChanged))
        configureNumberField(colsField, action: #selector(gridChanged))
        configureNumberField(outerMarginField, action: #selector(marginsChanged))
        configureNumberField(innerGapField, action: #selector(marginsChanged))
        stickyCheckbox.title = NSLocalizedString("Keep pane open until Esc", tableName: "Main", value: "Keep pane open until Esc", comment: "")
        stickyCheckbox.target = self
        stickyCheckbox.action = #selector(toggleSticky)

        let gridRow = row([
            NSTextField(labelWithString: NSLocalizedString("Grid rows", tableName: "Main", value: "Grid rows", comment: "")), rowsField,
            NSTextField(labelWithString: NSLocalizedString("cols", tableName: "Main", value: "cols", comment: "")), colsField,
            NSTextField(labelWithString: NSLocalizedString("Outer margin", tableName: "Main", value: "Outer margin", comment: "")), outerMarginField,
            NSTextField(labelWithString: NSLocalizedString("Inner gap", tableName: "Main", value: "Inner gap", comment: "")), innerGapField,
            spacer(), stickyCheckbox
        ])

        // Table (left)
        let keyColumn = NSTableColumn(identifier: .init("key"))
        keyColumn.title = NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")
        keyColumn.width = 70
        let labelColumn = NSTableColumn(identifier: .init("label"))
        labelColumn.title = NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")
        labelColumn.width = 90
        let regionColumn = NSTableColumn(identifier: .init("region"))
        regionColumn.title = NSLocalizedString("Region", tableName: "Main", value: "Region", comment: "")
        regionColumn.width = 130
        for c in [keyColumn, labelColumn, regionColumn] { tableView.addTableColumn(c) }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.doubleAction = #selector(focusPicker)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addButton = smallButton("+", #selector(addBinding))
        let removeButton = smallButton("–", #selector(removeBinding))
        let importButton = NSButton(title: NSLocalizedString("Import…", tableName: "Main", value: "Import…", comment: ""), target: self, action: #selector(importKeymap))
        let exportButton = NSButton(title: NSLocalizedString("Export…", tableName: "Main", value: "Export…", comment: ""), target: self, action: #selector(exportKeymap))
        let tableButtons = row([addButton, removeButton, spacer(), importButton, exportButton])

        let leftStack = NSStackView(views: [scroll, tableButtons])
        leftStack.orientation = .vertical
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([leftStack.widthAnchor.constraint(equalToConstant: 300)])

        // Right editor
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] placement in self?.pickerChanged(placement) }
        NSLayoutConstraint.activate([
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        keyCaptureButton.onCapture = { [weak self] keyCode, mods in self?.keyCaptured(keyCode: keyCode, modifierFlags: mods) }
        let clearKeyButton = NSButton(title: NSLocalizedString("Clear", tableName: "Main", value: "Clear", comment: ""), target: self, action: #selector(clearKey))

        labelField.placeholderString = NSLocalizedString("optional name", tableName: "Main", value: "optional name", comment: "")
        labelField.target = self
        labelField.action = #selector(labelChanged)
        labelField.translatesAutoresizingMaskIntoConstraints = false

        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        rebuildDisplayPopup()

        let keyRow = row([
            NSTextField(labelWithString: NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")),
            keyCaptureButton, clearKeyButton, spacer(),
            NSTextField(labelWithString: NSLocalizedString("Display", tableName: "Main", value: "Display", comment: "")),
            displayPopup
        ])
        let labelRow = row([
            NSTextField(labelWithString: NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")),
            labelField
        ])
        NSLayoutConstraint.activate([labelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)])

        conflictLabel.textColor = .systemRed
        conflictLabel.font = .systemFont(ofSize: 11)

        let rightStack = NSStackView(views: [
            NSTextField(labelWithString: NSLocalizedString("Region (drag on the grid)", tableName: "Main", value: "Region (drag on the grid)", comment: "")),
            picker, keyRow, labelRow, conflictLabel
        ])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let split = NSStackView(views: [leftStack, rightStack])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 16
        split.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "Press the Placement Mode shortcut, then a single key to move the frontmost window. Map different keys to different regions so keyboard geography matches screen geography.",
            tableName: "Main",
            value: "Press the Placement Mode shortcut, then a single key to move the frontmost window. Map different keys to different regions so keyboard geography matches screen geography.",
            comment: ""))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let root = NSStackView(views: [topRow, gridRow, separator(), split, hint])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    // MARK: Model <-> controls

    private func syncControlsFromModel() {
        enableCheckbox.state = Defaults.placementModeEnabled.userEnabled ? .on : .off
        stickyCheckbox.state = Defaults.placementPaneSticky.enabled ? .on : .off
        rowsField.stringValue = String(keymap.grid.rows)
        colsField.stringValue = String(keymap.grid.cols)
        outerMarginField.stringValue = String(format: "%g", Double(keymap.outerMargin))
        innerGapField.stringValue = String(format: "%g", Double(keymap.innerGap))
        picker.grid = keymap.grid
    }

    private func reloadTable() {
        picker.grid = keymap.grid
        picker.otherPlacements = keymap.bindings.map { $0.placement }
        tableView.reloadData()
        refreshEditorForSelection()
    }

    private func selectRow(_ index: Int?) {
        if let index, index < keymap.bindings.count {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        refreshEditorForSelection()
    }

    private func refreshEditorForSelection() {
        let binding = selectedIndex.flatMap { keymap.bindings[safe: $0] }
        let enabled = binding != nil
        for control in [keyCaptureButton, labelField, displayPopup] as [NSControl] {
            control.isEnabled = enabled
        }
        picker.isEditable = enabled
        picker.placement = binding?.placement
        picker.otherPlacements = keymap.bindings
            .filter { $0.id != binding?.id }
            .map { $0.placement }
        picker.needsDisplay = true

        labelField.stringValue = binding?.label ?? ""
        keyCaptureButton.setKey(keyCode: binding?.keyCode ?? PlacementBinding.unassignedKeyCode,
                                modifierFlags: binding?.modifierFlags ?? 0)
        if let raw = binding?.placement.displayIndexRaw {
            displayPopup.selectItem(withTag: raw)
        } else {
            displayPopup.selectItem(withTag: displayCurrentTag)
        }
        updateConflictLabel()
    }

    private func updateConflictLabel() {
        guard let index = selectedIndex, let binding = keymap.bindings[safe: index] else {
            conflictLabel.stringValue = ""
            return
        }
        if binding.isAssigned,
           keymap.hasConflict(keyCode: binding.keyCode, modifierFlags: binding.modifierFlags, excluding: binding.id) {
            conflictLabel.stringValue = NSLocalizedString("That key is already used by another placement.", tableName: "Main", value: "That key is already used by another placement.", comment: "")
        } else {
            conflictLabel.stringValue = ""
        }
    }

    private func mutateSelected(_ transform: (inout PlacementBinding) -> Void) {
        guard let index = selectedIndex, index < keymap.bindings.count else { return }
        var binding = keymap.bindings[index]
        transform(&binding)
        keymap.bindings[index] = binding
        reloadRow(index)
        picker.otherPlacements = keymap.bindings.filter { $0.id != binding.id }.map { $0.placement }
        picker.needsDisplay = true
        updateConflictLabel()
    }

    private func reloadRow(_ index: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        Defaults.placementModeEnabled.enabled = enableCheckbox.state == .on
        PlacementModeManager.registerUnregisterShortcut()
    }

    @objc private func toggleSticky() {
        Defaults.placementPaneSticky.enabled = stickyCheckbox.state == .on
    }

    @objc private func gridChanged() {
        let rows = clampDimension(rowsField.integerValue)
        let cols = clampDimension(colsField.integerValue)
        keymap.grid = PlacementGrid(rows: rows, cols: cols)
        keymap.bindings = keymap.bindings.map {
            var b = $0
            b.placement = b.placement.normalized(in: keymap.grid)
            return b
        }
        rowsField.stringValue = String(keymap.grid.rows)
        colsField.stringValue = String(keymap.grid.cols)
        reloadTable()
    }

    @objc private func marginsChanged() {
        keymap.outerMargin = CGFloat(max(0, outerMarginField.doubleValue))
        keymap.innerGap = CGFloat(max(0, innerGapField.doubleValue))
        picker.needsDisplay = true
    }

    @objc private func addBinding() {
        let placement = GridPlacement(col: 0, row: 0, colSpan: keymap.grid.cols, rowSpan: keymap.grid.rows)
        keymap.bindings.append(PlacementBinding(label: "", placement: placement))
        reloadTable()
        selectRow(keymap.bindings.count - 1)
        view.window?.makeFirstResponder(keyCaptureButton)
    }

    @objc private func removeBinding() {
        guard let index = selectedIndex else { return }
        keymap.bindings.remove(at: index)
        reloadTable()
        selectRow(keymap.bindings.isEmpty ? nil : min(index, keymap.bindings.count - 1))
    }

    @objc private func focusPicker() {
        view.window?.makeFirstResponder(picker)
    }

    @objc private func clearKey() {
        mutateSelected { $0.keyCode = PlacementBinding.unassignedKeyCode; $0.modifierFlags = 0 }
        refreshEditorForSelection()
    }

    @objc private func labelChanged() {
        mutateSelected { $0.label = labelField.stringValue }
    }

    @objc private func displayChanged() {
        let tag = displayPopup.selectedTag()
        mutateSelected {
            $0.placement.displayIndexRaw = (tag == displayCurrentTag) ? nil : tag
        }
    }

    private func keyCaptured(keyCode: Int, modifierFlags: UInt) {
        mutateSelected {
            $0.keyCode = keyCode
            $0.modifierFlags = modifierFlags & placementModifierMask
        }
        keyCaptureButton.setKey(keyCode: keyCode, modifierFlags: modifierFlags)
        updateConflictLabel()
    }

    private func pickerChanged(_ placement: GridPlacement) {
        mutateSelected {
            $0.placement.col = placement.col
            $0.placement.row = placement.row
            $0.placement.colSpan = placement.colSpan
            $0.placement.rowSpan = placement.rowSpan
        }
    }

    // MARK: Import / export

    @objc private func exportKeymap() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PlacementKeymap.json"
        panel.allowedFileTypes = ["json"]
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self.keymap) {
                try? data.write(to: url)
            }
        }
    }

    @objc private func importKeymap() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let data = try? Data(contentsOf: url),
                  let imported = try? JSONDecoder().decode(PlacementKeymap.self, from: data)
            else { return }
            self.keymap = imported
            self.syncControlsFromModel()
            self.reloadTable()
            self.selectRow(imported.bindings.isEmpty ? nil : 0)
        }
    }

    // MARK: Display popup

    private let displayCurrentTag = -100
    private let displayNextTag = -1

    private func rebuildDisplayPopup() {
        displayPopup.removeAllItems()
        addPopupItem(NSLocalizedString("Current display", tableName: "Main", value: "Current display", comment: ""), tag: displayCurrentTag)
        addPopupItem(NSLocalizedString("Next display", tableName: "Main", value: "Next display", comment: ""), tag: displayNextTag)
        let count = max(NSScreen.screens.count, 1)
        for i in 0..<count {
            addPopupItem(String(format: NSLocalizedString("Display %d", tableName: "Main", value: "Display %d", comment: ""), i + 1), tag: i)
        }
    }

    private func addPopupItem(_ title: String, tag: Int) {
        displayPopup.addItem(withTitle: title)
        displayPopup.lastItem?.tag = tag
    }

    // MARK: Small view helpers

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.setButtonType(.momentaryPushIn)
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 30)])
        return b
    }
    private func configureNumberField(_ field: NSTextField, action: Selector) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.target = self
        field.action = action
        NSLayoutConstraint.activate([field.widthAnchor.constraint(equalToConstant: 52)])
    }
    private func clampDimension(_ value: Int) -> Int {
        max(1, min(value == 0 ? 6 : value, PlacementGrid.maxDimension))
    }
}

// MARK: - Table data source / delegate

extension PlacementConfigViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { keymap.bindings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let binding = keymap.bindings[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch id {
        case "key":
            if binding.isAssigned {
                let s = MASShortcut(keyCode: binding.keyCode,
                                    modifierFlags: NSEvent.ModifierFlags(rawValue: binding.modifierFlags))
                text = [s.modifierFlagsString, s.keyCodeString].compactMap { $0 }.joined()
            } else {
                text = "—"
            }
        case "label":
            text = binding.label
        case "region":
            text = binding.placement.regionDescription(in: keymap.grid)
        default:
            text = ""
        }

        let identifier = NSUserInterfaceItemIdentifier("cell_\(id)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            c.identifier = identifier
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshEditorForSelection()
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
