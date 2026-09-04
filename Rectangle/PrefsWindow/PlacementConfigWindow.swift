/// PlacementConfigWindow.swift
///
/// The Divvy-style configuration UI: pick a grid size, then for each key draw a
/// rectangular region on the grid and assign a single keystroke to it. Hosted as
/// the "Placements" tab of Snappy Settings (Main.storyboard); multi-window
/// Layouts is its own tab, in PlacementConfigViews.swift. Programmatic AppKit
/// laid out to feel like a macOS System Settings pane.

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
    private let timeoutField = NSTextField()
    private let colsStepper = NSStepper()
    private let rowsStepper = NSStepper()
    private let colsField = NSTextField()
    private let rowsField = NSTextField()
    private let outerMarginField = NSTextField()
    private let innerGapField = NSTextField()

    private let tableView = DeletableTableView()
    private lazy var addRemoveControl = makeAddRemove(target: self, action: #selector(addRemoveChanged))
    private let picker = PlacementGridPickerView()
    private let keyCaptureButton = KeyCaptureButton()
    private let clearKeyButton = NSButton()
    private let labelField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let conflictLabel = NSTextField(labelWithString: "")

    private var generalGrid: NSGridView?
    /// Held as the row itself rather than an index: every insertion into the
    /// General card used to shift a hard-coded position and silently hide the
    /// wrong control.
    private var revealDelayRow: NSGridRow?
    private var detailGrid: NSGridView?
    private let conflictRowIndex = 1
    private let placementsEmptyLabel = emptyStateLabel(
        NSLocalizedString("No placements yet — click + to add one.", tableName: "Main", value: "No placements yet — click + to add one.", comment: ""))

    private let revealAlwaysTag = 0, revealDelayTag = 1, revealNeverTag = 2
    private let displayCurrentTag = -100, displayNextTag = -1

    // The two columns of the Placements pane, aligned to the General / Grid
    // cards above so the layout reads as two consistent columns top to bottom.
    private var placementsLeftColumn = NSView()
    private var placementsRightColumn = NSView()

    /// The cards that go dim when Placement Mode is switched off.
    private var governedCards: [NSView] = []

    private let placementsRoot = NSView()

    private var selectedIndex: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: SettingsTabViewController.paneWidth, height: 560))
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
        updatePreferredSize()
    }

    /// Tell the enclosing tab controller exactly how tall this pane wants to be,
    /// so nothing gets vertically compressed to fit a stale frame.
    private func updatePreferredSize() {
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        if abs(preferredContentSize.height - fit.height) > 0.5 || abs(preferredContentSize.width - fit.width) > 0.5 {
            preferredContentSize = fit
        }
    }

    // MARK: Layout

    private func buildLayout() {
        placementsRoot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placementsRoot)

        // Width is pinned by SettingsTabViewController, which gives every pane
        // the same one so the window does not resize between tabs.
        NSLayoutConstraint.activate([
            // Setting preferredContentSize replaces the pane view's own width
            // constraint with AppKit's, so the shared width has to be asserted
            // by the content instead — otherwise the window shrinks to whatever
            // these cards happen to need and stops matching the other tabs.
            placementsRoot.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsTabViewController.paneWidth),
            placementsRoot.topAnchor.constraint(equalTo: view.topAnchor, constant: PlacementUI.paneTopInset),
            placementsRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placementsRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            placementsRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildPlacementsColumns() // populates placementsLeftColumn / placementsRightColumn
        let general = titledCard(NSLocalizedString("General", tableName: "Main", value: "General", comment: ""), buildGeneralGrid())
        let gridCard = titledCard(NSLocalizedString("Grid", tableName: "Main", value: "Grid", comment: ""), buildGridGrid())
        // Region hugs its content and sets the row height; Placements fills to
        // match so the two cards line up top and bottom.
        let placementsCard = titledCard(NSLocalizedString("Placements", tableName: "Main", value: "Placements", comment: ""), placementsLeftColumn, fillsHeight: true)
        let regionCard = titledCard(NSLocalizedString("Region — drag on the grid", tableName: "Main", value: "Region — drag on the grid", comment: ""), placementsRightColumn)

        for v in [general, gridCard, placementsCard, regionCard] {
            v.translatesAutoresizingMaskIntoConstraints = false
            placementsRoot.addSubview(v)
        }
        // Everything the Placement Mode switch governs. The General card is
        // deliberately not in here - it holds the switch itself.
        governedCards = [gridCard, placementsCard, regionCard]

        NSLayoutConstraint.activate([
            // Top row: General | Grid, equal widths.
            general.topAnchor.constraint(equalTo: placementsRoot.topAnchor, constant: 4),
            general.leadingAnchor.constraint(equalTo: placementsRoot.leadingAnchor, constant: PlacementUI.outerMargin),

            gridCard.topAnchor.constraint(equalTo: general.topAnchor),
            gridCard.leadingAnchor.constraint(equalTo: general.trailingAnchor, constant: PlacementUI.columnGutter),
            gridCard.trailingAnchor.constraint(equalTo: placementsRoot.trailingAnchor, constant: -PlacementUI.outerMargin),
            gridCard.widthAnchor.constraint(equalTo: general.widthAnchor),
            gridCard.bottomAnchor.constraint(equalTo: general.bottomAnchor),

            // Bottom row: Placements | Region, same split, bottoms aligned.
            placementsCard.topAnchor.constraint(equalTo: general.bottomAnchor, constant: PlacementUI.cardRowGap),
            placementsCard.leadingAnchor.constraint(equalTo: general.leadingAnchor),
            placementsCard.trailingAnchor.constraint(equalTo: general.trailingAnchor),

            regionCard.topAnchor.constraint(equalTo: placementsCard.topAnchor),
            regionCard.leadingAnchor.constraint(equalTo: gridCard.leadingAnchor),
            regionCard.trailingAnchor.constraint(equalTo: gridCard.trailingAnchor),
            regionCard.bottomAnchor.constraint(equalTo: placementsCard.bottomAnchor),

            placementsRoot.bottomAnchor.constraint(equalTo: placementsCard.bottomAnchor, constant: 18),
        ])
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

        configureNumberField(timeoutField, width: 46, action: #selector(timeoutChanged))
        let timeoutRow = pair(timeoutField, caption: NSLocalizedString("seconds", tableName: "Main", value: "seconds", comment: ""))

        let grid = formGrid([
            [rightLabel(NSLocalizedString("Placement Mode", tableName: "Main", value: "Placement Mode", comment: "")), leadingWrap(enableSwitch)],
            [rightLabel(NSLocalizedString("Keep pane open", tableName: "Main", value: "Keep pane open", comment: "")),
             captioned(stickySwitch, NSLocalizedString("until Esc", tableName: "Main", value: "until Esc", comment: ""))],
            [rightLabel(NSLocalizedString("Close after", tableName: "Main", value: "Close after", comment: "")), timeoutRow],
            [rightLabel(NSLocalizedString("Shortcut", tableName: "Main", value: "Shortcut", comment: "")), shortcutView],
            [rightLabel(NSLocalizedString("Show map", tableName: "Main", value: "Show map", comment: "")), leadingWrap(revealPopup)],
            [rightLabel(NSLocalizedString("Reveal delay", tableName: "Main", value: "Reveal delay", comment: "")), delayRow],
        ])
        generalGrid = grid
        // Looked up from the view itself, so inserting rows above it is safe.
        revealDelayRow = grid.cell(for: delayRow)?.row
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
            [rightLabel(NSLocalizedString("Columns", tableName: "Main", value: "Columns", comment: "")), stepperRow(colsField, colsStepper)],
            [rightLabel(NSLocalizedString("Rows", tableName: "Main", value: "Rows", comment: "")), stepperRow(rowsField, rowsStepper)],
            [rightLabel(NSLocalizedString("Outer margin", tableName: "Main", value: "Outer margin", comment: "")), pair(outerMarginField, caption: "px")],
            [rightLabel(NSLocalizedString("Inner gap", tableName: "Main", value: "Inner gap", comment: "")), pair(innerGapField, caption: "px")],
        ])
    }

    private func buildPlacementsColumns() {
        // Left column: table + add/remove + import/export.
        let scroll = styledScroll(wrapping: tableView, columns: [
            ("key", NSLocalizedString("Key", tableName: "Main", value: "Key", comment: ""), 50),
            ("label", NSLocalizedString("Label", tableName: "Main", value: "Label", comment: ""), 84),
            ("region", NSLocalizedString("Region", tableName: "Main", value: "Region", comment: ""), 130),
        ])
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(captureKeyForSelection)
        tableView.onDelete = { [weak self] in self?.removeBinding() }

        let importButton = smallButton(NSLocalizedString("Import…", tableName: "Main", value: "Import…", comment: ""), target: self, action: #selector(importKeymap))
        let exportButton = smallButton(NSLocalizedString("Export…", tableName: "Main", value: "Export…", comment: ""), target: self, action: #selector(exportKeymap))

        let left = placementsLeftColumn
        left.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, placementsEmptyLabel, addRemoveControl, importButton, exportButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: left.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            placementsEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placementsEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placementsEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
            addRemoveControl.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addRemoveControl.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            addRemoveControl.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            exportButton.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            importButton.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -6),
        ])

        // Right column: the grid picker is the centrepiece, centred; the
        // Key / Label / Display form sits below it. Card hugs this content.
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
        commitOnEndEditing(labelField)
        labelField.setContentCompressionResistancePriority(.required, for: .vertical)

        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        rebuildDisplayPopup()

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed
        conflictLabel.lineBreakMode = .byWordWrapping
        conflictLabel.maximumNumberOfLines = 2

        let keyRow = hStack([keyCaptureButton, clearKeyButton], spacing: 6)
        let detailGrid = formGrid([
            [rightLabel(NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")), keyRow],
            [NSView(), conflictLabel],
            [rightLabel(NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")), fillWrap(labelField)],
            [rightLabel(NSLocalizedString("Display", tableName: "Main", value: "Display", comment: "")), leadingWrap(displayPopup)],
        ])
        detailGrid.setContentHuggingPriority(.required, for: .vertical)
        // Without this the row can be squeezed to fit the Placements card's
        // minimum height, which squashes the popup and eats the card's bottom
        // padding. Resisting compression makes this column set the row height.
        detailGrid.setContentCompressionResistancePriority(.required, for: .vertical)
        for c in [keyCaptureButton, clearKeyButton, labelField, displayPopup] as [NSControl] {
            c.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        detailGrid.row(at: conflictRowIndex).isHidden = true // shown only on conflict
        self.detailGrid = detailGrid

        let right = placementsRightColumn
        right.translatesAutoresizingMaskIntoConstraints = false
        for v in [picker, detailGrid] {
            v.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(v)
        }
        // The picker stands in for the screen: it fills the card's width and
        // takes a 16:9 height, so the grid cells are shaped like real regions.
        picker.activateScreenAspectConstraint()
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: right.topAnchor),
            picker.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: right.trailingAnchor),

            detailGrid.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 14),
            detailGrid.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            detailGrid.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor),
            detailGrid.bottomAnchor.constraint(equalTo: right.bottomAnchor),
        ])
    }

    // MARK: Form helpers

    private func configureNumberField(_ field: NSTextField, width: CGFloat, action: Selector) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.target = self
        field.action = action
        commitOnEndEditing(field)
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
        timeoutField.stringValue = String(format: "%g", Double(Defaults.placementPaneTimeout.value))
        updateRevealDelayRowVisibility()
        updateTimeoutFieldEnabled()

        colsField.stringValue = String(keymap.grid.cols)
        rowsField.stringValue = String(keymap.grid.rows)
        colsStepper.integerValue = keymap.grid.cols
        rowsStepper.integerValue = keymap.grid.rows
        outerMarginField.stringValue = String(format: "%g", Double(keymap.outerMargin))
        innerGapField.stringValue = String(format: "%g", Double(keymap.innerGap))
        picker.grid = keymap.grid
        applyEnabledState()
    }

    private func reloadTable() {
        picker.grid = keymap.grid
        tableView.reloadData()
        placementsEmptyLabel.isHidden = !keymap.bindings.isEmpty
        refreshEditorForSelection()
    }

    /// "Reveal delay" only matters when the map is shown after a pause — hide
    /// the row otherwise so the General card stays compact.
    /// With the pane pinned open until Esc there is no timeout to set, and a
    /// dimmed field says that better than a footnote would.
    private func updateTimeoutFieldEnabled() {
        timeoutField.isEnabled = !Defaults.placementPaneSticky.enabled
    }

    private func updateRevealDelayRowVisibility() {
        let show = Defaults.placementMapReveal.value == .afterDelay
        revealDelayField.isEnabled = show
        revealDelayRow?.isHidden = !show
    }

    private func selectRow(_ index: Int?) {
        if let index, index < keymap.bindings.count {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        refreshEditorForSelection()
    }

    /// Enabled state has two independent inputs - whether a row is selected and
    /// whether placement mode is on - so both go through here. Setting
    /// `isEnabled` from two places instead would mean last-writer-wins, and
    /// selecting a row would quietly relight a pane the switch had dimmed.
    private func applyEnabledState() {
        let modeOn = Defaults.placementModeEnabled.userEnabled
        let hasSelection = selectedIndex.flatMap { keymap.bindings[safe: $0] } != nil
        let editable = modeOn && hasSelection

        for control in [keyCaptureButton, labelField, displayPopup, clearKeyButton] as [NSControl] {
            control.isEnabled = editable
        }
        addRemoveControl.setEnabled(modeOn, forSegment: 0)
        addRemoveControl.setEnabled(editable, forSegment: 1)
        picker.isEditable = editable

        for card in governedCards { setControlsEnabled(modeOn, in: card) }
        tableView.isEnabled = modeOn
    }

    /// Walks a card so a whole section dims together. Re-applied after, so the
    /// selection-dependent controls above keep the last word.
    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for sub in view.subviews {
            if let control = sub as? NSControl, !(control is NSTableView) { control.isEnabled = enabled }
            setControlsEnabled(enabled, in: sub)
        }
    }

    private func refreshEditorForSelection() {
        let binding = selectedIndex.flatMap { keymap.bindings[safe: $0] }
        let enabled = binding != nil
        picker.isEditable = enabled
        picker.placement = binding?.placement
        picker.otherPlacements = keymap.bindings.filter { $0.id != binding?.id }.map { $0.placement }
        picker.needsDisplay = true

        labelField.stringValue = binding?.label ?? ""
        keyCaptureButton.setKey(keyCode: binding?.keyCode ?? PlacementBinding.unassignedKeyCode,
                                modifierFlags: binding?.modifierFlags ?? 0)
        displayPopup.selectItem(withTag: binding?.placement.displayIndexRaw ?? displayCurrentTag)
        updateConflictLabel()
        applyEnabledState()
    }

    private func updateConflictLabel() {
        guard let i = selectedIndex, let b = keymap.bindings[safe: i], b.isAssigned,
              let holder = keymap.holder(ofKeyCode: b.keyCode, modifierFlags: b.modifierFlags, excluding: b.id)
        else {
            conflictLabel.stringValue = ""
            detailGrid?.row(at: conflictRowIndex).isHidden = true
            return
        }
        conflictLabel.stringValue = placementConflictMessage(keyCode: b.keyCode,
                                                             modifierFlags: b.modifierFlags,
                                                             holder: holder)
        detailGrid?.row(at: conflictRowIndex).isHidden = false
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
        // Breaking the shortcut binding doesn't close a pane that is already up.
        if enableSwitch.state == .off { PlacementModeController.shared.deactivate() }
        applyEnabledState()
    }
    @objc private func toggleSticky() {
        Defaults.placementPaneSticky.enabled = stickySwitch.state == .on
        updateTimeoutFieldEnabled()
    }
    @objc private func revealChanged() {
        let tag = revealPopup.selectedTag()
        Defaults.placementMapReveal.value = PlacementMapReveal(rawValue: tag) ?? .afterDelay
        updateRevealDelayRowVisibility()
    }
    @objc private func revealDelayChanged() {
        Defaults.placementMapRevealDelay.value = max(0.05, min(revealDelayField.floatValue, 5))
        revealDelayField.stringValue = String(format: "%g", Double(Defaults.placementMapRevealDelay.value))
    }
    @objc private func timeoutChanged() {
        Defaults.placementPaneTimeout.value = max(1, min(timeoutField.floatValue, 30))
        timeoutField.stringValue = String(format: "%g", Double(Defaults.placementPaneTimeout.value))
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
        // Layout slots live on the same grid. resolve() clamps them at apply
        // time so windows still land right, but an exported keymap would carry
        // regions that don't fit its own grid.
        keymap.layouts = keymap.layouts.map { layout in
            var l = layout
            l.slots = l.slots.map { var s = $0; s.placement = s.placement.normalized(in: keymap.grid); return s }
            return l
        }
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
        // Listening straight away, so a new placement can be keyed without a
        // trip to the Set Key button.
        keyCaptureButton.armCapture()
    }
    private func removeBinding() {
        guard let index = selectedIndex else { return }
        keymap.bindings.remove(at: index)
        reloadTable()
        selectRow(keymap.bindings.isEmpty ? nil : min(index, keymap.bindings.count - 1))
    }
    /// Double-clicking a row used to focus the grid picker, which does not take
    /// first responder and has no keyboard editing — so it did nothing. Setting
    /// the key is what a double-click on a row is reaching for.
    @objc private func captureKeyForSelection() { keyCaptureButton.armCapture() }
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
        // Drawing a region on a placement that has no key yet is always
        // followed by choosing one, so listen for it rather than making the
        // user go and click Set Key. An existing key is left alone: dragging to
        // adjust a bound region must not swallow the next keystroke.
        if selectedIndex.flatMap({ keymap.bindings[safe: $0] })?.isAssigned == false {
            keyCaptureButton.armCapture()
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
            guard response == .OK, let url = panel.url, let self else { return }
            // Alerts have to wait for the sheet to finish dismissing; running a
            // modal on top of a closing sheet leaves the window wedged.
            DispatchQueue.main.async { self.completeImport(from: url) }
        }
    }

    /// Import replaces the whole keymap and there is no undo, so it asks first
    /// and says so when the file turns out not to be one.
    private func completeImport(from url: URL) {
        // PlacementKeymap decodes every field with a default, so any JSON object
        // at all decodes into an empty keymap. Require the file to actually
        // carry one of the keys a keymap has, or a stray .json would import as
        // "no placements, no layouts" and read as a successful wipe.
        let looksLikeKeymap = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .map { $0.keys.contains { ["bindings", "layouts", "grid"].contains($0) } } ?? false

        guard looksLikeKeymap,
              let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(PlacementKeymap.self, from: data)
        else {
            AlertUtil.oneButtonAlert(
                question: NSLocalizedString("That file isn’t a Snappy keymap", tableName: "Main", value: "That file isn’t a Snappy keymap", comment: ""),
                text: String(format: NSLocalizedString("“%@” couldn’t be read as one. Export a keymap from this pane to see the format Snappy expects.", tableName: "Main", value: "“%@” couldn’t be read as one. Export a keymap from this pane to see the format Snappy expects.", comment: ""),
                             url.lastPathComponent))
            return
        }

        guard confirmReplacingKeymap() else { return }

        keymap = imported
        syncControlsFromModel()
        reloadTable()
        selectRow(imported.bindings.isEmpty ? nil : 0)
    }

    /// True if the current map is empty, or the user accepted losing it. Offers
    /// to export first, since that is the only way back.
    private func confirmReplacingKeymap() -> Bool {
        let placements = keymap.bindings.count
        let layouts = keymap.layouts.count
        guard placements + layouts > 0 else { return true }

        let text = String(format: NSLocalizedString("This replaces %1$d placements and %2$d layouts. You can’t undo it.", tableName: "Main", value: "This replaces %1$d placements and %2$d layouts. You can’t undo it.", comment: ""),
                          placements, layouts)
        let response = AlertUtil.threeButtonAlert(
            question: NSLocalizedString("Replace your placements and layouts?", tableName: "Main", value: "Replace your placements and layouts?", comment: ""),
            text: text,
            buttonOneText: NSLocalizedString("Replace", tableName: "Main", value: "Replace", comment: ""),
            buttonTwoText: NSLocalizedString("Export Current First…", tableName: "Main", value: "Export Current First…", comment: ""),
            buttonThreeText: NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: ""))

        switch response {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            // Save the old map, then leave the import to a second, deliberate go.
            exportKeymap()
            return false
        default:
            return false
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
            let tf = tableCellTextField(mono: id == "key")
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
