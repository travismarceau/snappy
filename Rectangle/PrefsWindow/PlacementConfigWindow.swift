/// PlacementConfigWindow.swift
///
/// The Divvy-style configuration UI: pick a grid size, then for each key draw a
/// rectangular region on the grid and assign a single keystroke to it. Hosted as
/// the "Placement" tab of Rectangle Settings (Main.storyboard). Programmatic
/// AppKit laid out to feel like a macOS System Settings pane.

import Cocoa
import MASShortcut

// MARK: - View controller

final class PlacementConfigViewController: NSViewController {

    private var keymap = Defaults.placementKeymap.typedValue ?? .empty {
        didSet { Defaults.placementKeymap.typedValue = keymap }
    }

    private let recordingObserver = ShortcutRecordingObserver()

    private let enableSwitch = NSSwitch()
    private let stickySwitch = NSSwitch()
    private let revealPopup = NSPopUpButton()
    private let revealDelayField = NSTextField()
    private let colsStepper = NSStepper()
    private let rowsStepper = NSStepper()
    private let colsField = NSTextField()
    private let rowsField = NSTextField()
    private let outerMarginField = NSTextField()
    private let innerGapField = NSTextField()

    private let tableView = NSTableView()
    private let addRemoveControl = NSSegmentedControl()
    private let picker = PlacementGridPickerView()
    private let keyCaptureButton = KeyCaptureButton()
    private let clearKeyButton = NSButton()
    private let labelField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let conflictLabel = NSTextField(labelWithString: "")

    private let revealAlwaysTag = 0, revealDelayTag = 1, revealNeverTag = 2
    private let displayCurrentTag = -100, displayNextTag = -1

    // The two columns of the Placements pane, aligned to the General / Grid
    // cards above so the layout reads as two consistent columns top to bottom.
    private var placementsLeftColumn = NSView()
    private var placementsRightColumn = NSView()

    // Placements vs. multi-window Layouts, toggled by a segmented control.
    private let modeControl = NSSegmentedControl(labels: [
        NSLocalizedString("Placements", tableName: "Main", value: "Placements", comment: ""),
        NSLocalizedString("Layouts", tableName: "Main", value: "Layouts", comment: ""),
    ], trackingMode: .selectOne, target: nil, action: nil)
    private let placementsRoot = NSView()
    private lazy var layoutsRoot = LayoutsPaneView()

    private var selectedIndex: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 720))
        view.wantsLayer = true
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        syncControlsFromModel()
        reloadTable()
        selectRow(keymap.bindings.isEmpty ? nil : 0)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Pick up any changes made outside this tab (e.g. imported config).
        if keymap != (Defaults.placementKeymap.typedValue ?? .empty) {
            keymap = Defaults.placementKeymap.typedValue ?? .empty
            syncControlsFromModel()
            reloadTable()
            selectRow(keymap.bindings.isEmpty ? nil : 0)
        }
        if !layoutsRoot.isHidden { layoutsRoot.reload() }
    }

    // MARK: Layout

    private func buildLayout() {
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        for root in [placementsRoot, layoutsRoot] {
            root.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(root)
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 14),
                root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        layoutsRoot.isHidden = true

        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        let placementsPane = buildPlacementsPane() // populates placementsLeftColumn / placementsRightColumn
        let general = titledCard(NSLocalizedString("General", tableName: "Main", value: "General", comment: ""), buildGeneralGrid())
        let gridCard = titledCard(NSLocalizedString("Grid", tableName: "Main", value: "Grid", comment: ""), buildGridGrid())
        let placements = titledCard(NSLocalizedString("Placements", tableName: "Main", value: "Placements", comment: ""), placementsPane, fillsHeight: true)

        for v in [general, gridCard, placements] {
            v.translatesAutoresizingMaskIntoConstraints = false
            placementsRoot.addSubview(v)
        }

        NSLayoutConstraint.activate([
            // General and Grid share the top row, equal widths.
            general.topAnchor.constraint(equalTo: placementsRoot.topAnchor, constant: 4),
            general.leadingAnchor.constraint(equalTo: placementsRoot.leadingAnchor, constant: 20),

            gridCard.topAnchor.constraint(equalTo: general.topAnchor),
            gridCard.leadingAnchor.constraint(equalTo: general.trailingAnchor, constant: 16),
            gridCard.trailingAnchor.constraint(equalTo: placementsRoot.trailingAnchor, constant: -20),
            gridCard.widthAnchor.constraint(equalTo: general.widthAnchor),
            gridCard.bottomAnchor.constraint(equalTo: general.bottomAnchor),

            // Placements fills the rest, full width.
            placements.topAnchor.constraint(equalTo: general.bottomAnchor, constant: 16),
            placements.leadingAnchor.constraint(equalTo: placementsRoot.leadingAnchor, constant: 20),
            placements.trailingAnchor.constraint(equalTo: placementsRoot.trailingAnchor, constant: -20),
            placements.bottomAnchor.constraint(equalTo: placementsRoot.bottomAnchor, constant: -18),

            // Keep the Placements columns aligned to the cards above: the table
            // ends where General ends, the region editor starts where Grid starts.
            placementsLeftColumn.trailingAnchor.constraint(equalTo: general.trailingAnchor),
            placementsRightColumn.leadingAnchor.constraint(equalTo: gridCard.leadingAnchor),
        ])
    }

    @objc private func modeChanged() {
        let layouts = modeControl.selectedSegment == 1
        placementsRoot.isHidden = layouts
        layoutsRoot.isHidden = !layouts
        if layouts { layoutsRoot.reload() }
    }

    /// A section header above a rounded, bordered card that wraps `content` with
    /// interior padding. Everything pinned with explicit constraints. When
    /// `fillsHeight` is false the card hugs its content (but can be stretched by
    /// an outside constraint); when true the content is pinned to fill the card.
    private func titledCard(_ title: String, _ content: NSView, fillsHeight: Bool = false) -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        let contentBottom = content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        contentBottom.priority = fillsHeight ? .required : .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            contentBottom,
            card.bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 14),
        ])

        container.addSubview(header)
        container.addSubview(card)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func buildGeneralGrid() -> NSView {
        enableSwitch.target = self; enableSwitch.action = #selector(toggleEnabled)
        stickySwitch.target = self; stickySwitch.action = #selector(toggleSticky)

        let shortcutView = MASShortcutView(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        shortcutView.shortcutValidator = AppShortcutValidator(defaultsKey: PlacementModeManager.defaultsKey)
        shortcutView.setAssociatedUserDefaultsKey(PlacementModeManager.defaultsKey, withTransformerName: MASDictionaryTransformerName)
        recordingObserver.observe([shortcutView])
        PlacementModeManager.initShortcut()

        revealPopup.target = self; revealPopup.action = #selector(revealChanged)
        addPopupItem(revealPopup, NSLocalizedString("Always", tableName: "Main", value: "Always", comment: ""), tag: revealAlwaysTag)
        addPopupItem(revealPopup, NSLocalizedString("After a short pause", tableName: "Main", value: "After a short pause", comment: ""), tag: revealDelayTag)
        addPopupItem(revealPopup, NSLocalizedString("Never", tableName: "Main", value: "Never", comment: ""), tag: revealNeverTag)

        configureNumberField(revealDelayField, width: 46, action: #selector(revealDelayChanged))
        let delayRow = pair(revealDelayField, caption: NSLocalizedString("seconds", tableName: "Main", value: "seconds", comment: ""))

        let grid = formGrid([
            [label(NSLocalizedString("Placement Mode", tableName: "Main", value: "Placement Mode", comment: "")), leading(enableSwitch)],
            [label(NSLocalizedString("Keep pane open", tableName: "Main", value: "Keep pane open", comment: "")),
             captioned(stickySwitch, NSLocalizedString("until Esc", tableName: "Main", value: "until Esc", comment: ""))],
            [label(NSLocalizedString("Shortcut", tableName: "Main", value: "Shortcut", comment: "")), shortcutView],
            [label(NSLocalizedString("Show map", tableName: "Main", value: "Show map", comment: "")), leading(revealPopup)],
            [label(NSLocalizedString("Reveal delay", tableName: "Main", value: "Reveal delay", comment: "")), delayRow],
        ])
        return grid
    }

    private func buildGridGrid() -> NSView {
        configureStepper(colsStepper, action: #selector(gridChanged))
        configureStepper(rowsStepper, action: #selector(gridChanged))
        configureNumberField(colsField, width: 46, action: #selector(gridFieldChanged))
        configureNumberField(rowsField, width: 46, action: #selector(gridFieldChanged))
        configureNumberField(outerMarginField, width: 56, action: #selector(marginsChanged))
        configureNumberField(innerGapField, width: 56, action: #selector(marginsChanged))

        return formGrid([
            [label(NSLocalizedString("Columns", tableName: "Main", value: "Columns", comment: "")), stepperRow(colsField, colsStepper)],
            [label(NSLocalizedString("Rows", tableName: "Main", value: "Rows", comment: "")), stepperRow(rowsField, rowsStepper)],
            [label(NSLocalizedString("Outer margin", tableName: "Main", value: "Outer margin", comment: "")), pair(outerMarginField, caption: "px")],
            [label(NSLocalizedString("Inner gap", tableName: "Main", value: "Inner gap", comment: "")), pair(innerGapField, caption: "px")],
        ])
    }

    private func buildPlacementsPane() -> NSView {
        // Left: table + add/remove
        let keyCol = NSTableColumn(identifier: .init("key"))
        keyCol.title = NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")
        keyCol.width = 56
        let labelCol = NSTableColumn(identifier: .init("label"))
        labelCol.title = NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")
        labelCol.width = 80
        let regionCol = NSTableColumn(identifier: .init("region"))
        regionCol.title = NSLocalizedString("Region", tableName: "Main", value: "Region", comment: "")
        regionCol.width = 120
        for c in [keyCol, labelCol, regionCol] { tableView.addTableColumn(c) }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.doubleAction = #selector(focusPicker)
        if #available(macOS 11, *) { tableView.style = .inset }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addRemoveControl.segmentStyle = .separated
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.segmentCount = 2
        addRemoveControl.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        addRemoveControl.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        addRemoveControl.setWidth(30, forSegment: 0)
        addRemoveControl.setWidth(30, forSegment: 1)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveChanged)
        addRemoveControl.translatesAutoresizingMaskIntoConstraints = false

        let importButton = smallButton(NSLocalizedString("Import…", tableName: "Main", value: "Import…", comment: ""), #selector(importKeymap))
        let exportButton = smallButton(NSLocalizedString("Export…", tableName: "Main", value: "Export…", comment: ""), #selector(exportKeymap))

        // Left column: table filling the height, add/remove + import/export below.
        let left = placementsLeftColumn
        left.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, addRemoveControl, importButton, exportButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: left.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            addRemoveControl.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addRemoveControl.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            addRemoveControl.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            exportButton.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            importButton.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -6),
        ])

        // Right column: region picker + detail fields, sized to content.
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] p in self?.pickerChanged(p) }

        keyCaptureButton.onCapture = { [weak self] keyCode, mods in self?.keyCaptured(keyCode: keyCode, modifierFlags: mods) }
        clearKeyButton.title = NSLocalizedString("Clear", tableName: "Main", value: "Clear", comment: "")
        clearKeyButton.bezelStyle = .rounded
        clearKeyButton.controlSize = .small
        clearKeyButton.target = self
        clearKeyButton.action = #selector(clearKey)

        labelField.placeholderString = NSLocalizedString("optional name", tableName: "Main", value: "optional name", comment: "")
        labelField.target = self
        labelField.action = #selector(labelChanged)

        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        rebuildDisplayPopup()

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed

        let keyRow = hStack([keyCaptureButton, clearKeyButton], spacing: 6)
        let detailGrid = formGrid([
            [label(NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")), keyRow],
            [label(NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")), fill(labelField)],
            [label(NSLocalizedString("Display", tableName: "Main", value: "Display", comment: "")), leading(displayPopup)],
        ])

        let regionCaption = NSTextField(labelWithString: NSLocalizedString("Region — drag on the grid", tableName: "Main", value: "Region — drag on the grid", comment: ""))
        regionCaption.font = .systemFont(ofSize: 12)
        regionCaption.textColor = .secondaryLabelColor
        regionCaption.translatesAutoresizingMaskIntoConstraints = false

        let right = placementsRightColumn
        right.translatesAutoresizingMaskIntoConstraints = false
        for v in [regionCaption, picker, detailGrid, conflictLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(v)
        }
        NSLayoutConstraint.activate([
            regionCaption.topAnchor.constraint(equalTo: right.topAnchor),
            regionCaption.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            picker.topAnchor.constraint(equalTo: regionCaption.bottomAnchor, constant: 6),
            picker.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            picker.heightAnchor.constraint(equalToConstant: 160),
            detailGrid.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 12),
            detailGrid.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            detailGrid.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor),
            conflictLabel.topAnchor.constraint(equalTo: detailGrid.bottomAnchor, constant: 8),
            conflictLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            conflictLabel.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            conflictLabel.bottomAnchor.constraint(lessThanOrEqualTo: right.bottomAnchor),
        ])

        // Compose the two columns.
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(left)
        pane.addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: pane.topAnchor),
            left.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            // left.trailing and right.leading are pinned to the General / Grid
            // cards in buildLayout so the two columns line up top to bottom.
            right.topAnchor.constraint(equalTo: pane.topAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            right.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return pane
    }

    // MARK: Form helpers

    private func formGrid(_ rows: [[NSView]]) -> NSGridView {
        for row in rows { for v in row { v.translatesAutoresizingMaskIntoConstraints = false } }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        return grid
    }

    private func label(_ s: String) -> NSTextField {
        let tf = NSTextField(labelWithString: s)
        tf.alignment = .right
        tf.textColor = .labelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentHuggingPriority(.required, for: .horizontal)
        return tf
    }
    private func hStack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = align
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    private func leading(_ v: NSView) -> NSView { hStack([v, spacer()], spacing: 0) }
    private func fill(_ v: NSView) -> NSView {
        let s = hStack([v], spacing: 0)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return s
    }
    private func pair(_ field: NSView, caption: String) -> NSView {
        let cap = NSTextField(labelWithString: caption)
        cap.textColor = .secondaryLabelColor
        cap.font = .systemFont(ofSize: 11)
        return hStack([field, cap, spacer()], spacing: 6)
    }
    private func captioned(_ control: NSView, _ caption: String) -> NSView {
        let cap = NSTextField(labelWithString: caption)
        cap.textColor = .secondaryLabelColor
        cap.font = .systemFont(ofSize: 11)
        cap.lineBreakMode = .byTruncatingTail
        cap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return hStack([control, cap, spacer()], spacing: 8)
    }
    private func stepperRow(_ field: NSTextField, _ stepper: NSStepper) -> NSView {
        hStack([field, stepper, spacer()], spacing: 4)
    }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
    private func configureNumberField(_ field: NSTextField, width: CGFloat, action: Selector) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.target = self
        field.action = action
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func configureStepper(_ stepper: NSStepper, action: Selector) {
        stepper.minValue = 1
        stepper.maxValue = Double(PlacementGrid.maxDimension)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
    }
    private func addPopupItem(_ popup: NSPopUpButton, _ title: String, tag: Int) {
        popup.addItem(withTitle: title)
        popup.lastItem?.tag = tag
    }

    // MARK: Model <-> controls

    private func syncControlsFromModel() {
        enableSwitch.state = Defaults.placementModeEnabled.userEnabled ? .on : .off
        stickySwitch.state = Defaults.placementPaneSticky.enabled ? .on : .off
        revealPopup.selectItem(withTag: Defaults.placementMapReveal.value.rawValue)
        revealDelayField.stringValue = String(format: "%g", Double(Defaults.placementMapRevealDelay.value))
        revealDelayField.isEnabled = Defaults.placementMapReveal.value == .afterDelay

        colsField.stringValue = String(keymap.grid.cols)
        rowsField.stringValue = String(keymap.grid.rows)
        colsStepper.integerValue = keymap.grid.cols
        rowsStepper.integerValue = keymap.grid.rows
        outerMarginField.stringValue = String(format: "%g", Double(keymap.outerMargin))
        innerGapField.stringValue = String(format: "%g", Double(keymap.innerGap))
        picker.grid = keymap.grid
    }

    private func reloadTable() {
        picker.grid = keymap.grid
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
        for control in [keyCaptureButton, labelField, displayPopup, clearKeyButton] as [NSControl] {
            control.isEnabled = enabled
        }
        addRemoveControl.setEnabled(enabled, forSegment: 1)
        picker.isEditable = enabled
        picker.placement = binding?.placement
        picker.otherPlacements = keymap.bindings.filter { $0.id != binding?.id }.map { $0.placement }
        picker.needsDisplay = true

        labelField.stringValue = binding?.label ?? ""
        keyCaptureButton.setKey(keyCode: binding?.keyCode ?? PlacementBinding.unassignedKeyCode,
                                modifierFlags: binding?.modifierFlags ?? 0)
        displayPopup.selectItem(withTag: binding?.placement.displayIndexRaw ?? displayCurrentTag)
        updateConflictLabel()
    }

    private func updateConflictLabel() {
        guard let i = selectedIndex, let b = keymap.bindings[safe: i], b.isAssigned,
              keymap.hasConflict(keyCode: b.keyCode, modifierFlags: b.modifierFlags, excluding: b.id) else {
            conflictLabel.stringValue = ""
            return
        }
        conflictLabel.stringValue = NSLocalizedString("That key is already used by another placement.", tableName: "Main", value: "That key is already used by another placement.", comment: "")
    }

    private func mutateSelected(_ transform: (inout PlacementBinding) -> Void) {
        guard let index = selectedIndex, index < keymap.bindings.count else { return }
        var b = keymap.bindings[index]
        transform(&b)
        keymap.bindings[index] = b
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        picker.otherPlacements = keymap.bindings.filter { $0.id != b.id }.map { $0.placement }
        picker.needsDisplay = true
        updateConflictLabel()
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        Defaults.placementModeEnabled.enabled = enableSwitch.state == .on
        PlacementModeManager.registerUnregisterShortcut()
    }
    @objc private func toggleSticky() {
        Defaults.placementPaneSticky.enabled = stickySwitch.state == .on
    }
    @objc private func revealChanged() {
        let tag = revealPopup.selectedTag()
        Defaults.placementMapReveal.value = PlacementMapReveal(rawValue: tag) ?? .afterDelay
        revealDelayField.isEnabled = Defaults.placementMapReveal.value == .afterDelay
    }
    @objc private func revealDelayChanged() {
        Defaults.placementMapRevealDelay.value = max(0.05, min(revealDelayField.floatValue, 5))
        revealDelayField.stringValue = String(format: "%g", Double(Defaults.placementMapRevealDelay.value))
    }
    @objc private func gridChanged() {
        applyGrid(cols: colsStepper.integerValue, rows: rowsStepper.integerValue)
    }
    @objc private func gridFieldChanged() {
        applyGrid(cols: colsField.integerValue, rows: rowsField.integerValue)
    }
    private func applyGrid(cols: Int, rows: Int) {
        keymap.grid = PlacementGrid(rows: rows == 0 ? 6 : rows, cols: cols == 0 ? 6 : cols)
        keymap.bindings = keymap.bindings.map { var b = $0; b.placement = b.placement.normalized(in: keymap.grid); return b }
        colsField.stringValue = String(keymap.grid.cols); rowsField.stringValue = String(keymap.grid.rows)
        colsStepper.integerValue = keymap.grid.cols; rowsStepper.integerValue = keymap.grid.rows
        reloadTable()
    }
    @objc private func marginsChanged() {
        keymap.outerMargin = CGFloat(max(0, outerMarginField.doubleValue))
        keymap.innerGap = CGFloat(max(0, innerGapField.doubleValue))
        picker.needsDisplay = true
    }
    @objc private func addRemoveChanged() {
        if addRemoveControl.selectedSegment == 0 { addBinding() } else { removeBinding() }
    }
    private func addBinding() {
        let p = GridPlacement(col: 0, row: 0, colSpan: keymap.grid.cols, rowSpan: keymap.grid.rows)
        keymap.bindings.append(PlacementBinding(label: "", placement: p))
        reloadTable()
        selectRow(keymap.bindings.count - 1)
        view.window?.makeFirstResponder(keyCaptureButton)
    }
    private func removeBinding() {
        guard let index = selectedIndex else { return }
        keymap.bindings.remove(at: index)
        reloadTable()
        selectRow(keymap.bindings.isEmpty ? nil : min(index, keymap.bindings.count - 1))
    }
    @objc private func focusPicker() { view.window?.makeFirstResponder(picker) }
    @objc private func clearKey() {
        mutateSelected { $0.keyCode = PlacementBinding.unassignedKeyCode; $0.modifierFlags = 0 }
        refreshEditorForSelection()
    }
    @objc private func labelChanged() { mutateSelected { $0.label = labelField.stringValue } }
    @objc private func displayChanged() {
        let tag = displayPopup.selectedTag()
        mutateSelected { $0.placement.displayIndexRaw = (tag == displayCurrentTag) ? nil : tag }
    }
    private func keyCaptured(keyCode: Int, modifierFlags: UInt) {
        mutateSelected { $0.keyCode = keyCode; $0.modifierFlags = modifierFlags & placementModifierMask }
        keyCaptureButton.setKey(keyCode: keyCode, modifierFlags: modifierFlags)
        updateConflictLabel()
    }
    private func pickerChanged(_ p: GridPlacement) {
        mutateSelected {
            $0.placement.col = p.col; $0.placement.row = p.row
            $0.placement.colSpan = p.colSpan; $0.placement.rowSpan = p.rowSpan
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
            if let data = try? encoder.encode(self.keymap) { try? data.write(to: url) }
        }
    }
    @objc private func importKeymap() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let data = try? Data(contentsOf: url),
                  let imported = try? JSONDecoder().decode(PlacementKeymap.self, from: data) else { return }
            self.keymap = imported
            self.syncControlsFromModel()
            self.reloadTable()
            self.selectRow(imported.bindings.isEmpty ? nil : 0)
        }
    }

    private func rebuildDisplayPopup() {
        displayPopup.removeAllItems()
        addPopupItem(displayPopup, NSLocalizedString("Current display", tableName: "Main", value: "Current display", comment: ""), tag: displayCurrentTag)
        addPopupItem(displayPopup, NSLocalizedString("Next display", tableName: "Main", value: "Next display", comment: ""), tag: displayNextTag)
        for i in 0..<max(NSScreen.screens.count, 1) {
            addPopupItem(displayPopup, String(format: NSLocalizedString("Display %d", tableName: "Main", value: "Display %d", comment: ""), i + 1), tag: i)
        }
    }
}

// MARK: - Table data source / delegate

extension PlacementConfigViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { keymap.bindings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let b = keymap.bindings[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch id {
        case "key":
            if b.isAssigned {
                let s = MASShortcut(keyCode: b.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: b.modifierFlags))
                text = [s.modifierFlagsString, s.keyCodeString].compactMap { $0 }.joined()
            } else { text = "—" }
        case "label": text = b.label
        case "region": text = b.placement.regionDescription(in: keymap.grid)
        default: text = ""
        }

        let identifier = NSUserInterfaceItemIdentifier("cell_\(id)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = id == "key" ? .monospacedSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
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
        cell.textField?.textColor = (id == "region") ? .secondaryLabelColor : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshEditorForSelection()
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
