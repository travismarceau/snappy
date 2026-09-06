/// PlacementConfigViews.swift
///
/// The two custom controls used by `PlacementConfigViewController`:
///   • `KeyCaptureButton` — records a single keystroke (not a MASShortcut chord).
///   • `PlacementGridPickerView` — rubber-band a rectangular block of grid cells.

import Cocoa
import Carbon.HIToolbox
import MASShortcut

// MARK: - Single-key capture

final class KeyCaptureButton: NSButton {

    var onCapture: ((_ keyCode: Int, _ modifierFlags: UInt) -> Void)?

    private var capturing = false
    private var idleTitle = NSLocalizedString("Set Key…", tableName: "Main", value: "Set Key…", comment: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        title = idleTitle
        target = self
        action = #selector(beginCapture)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
    }

    override var acceptsFirstResponder: Bool { true }

    func setKey(keyCode: Int, modifierFlags: UInt) {
        capturing = false
        if keyCode < 0 {
            idleTitle = NSLocalizedString("Set Key…", tableName: "Main", value: "Set Key…", comment: "")
        } else {
            let s = MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
            let text = [s.modifierFlagsString, s.keyCodeString].compactMap { $0 }.joined()
            idleTitle = text.isEmpty ? "?" : text
        }
        title = idleTitle
        contentTintColor = nil
    }

    /// Take focus and start listening, without the user having to click. Used
    /// right after a binding is created or its region drawn, so the next key
    /// pressed is the one being bound.
    func armCapture() {
        beginCapture()
    }

    @objc private func beginCapture() {
        guard isEnabled else { return }
        capturing = true
        title = NSLocalizedString("Type a key…", tableName: "Main", value: "Type a key…", comment: "")
        contentTintColor = .controlAccentColor
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard capturing else { super.keyDown(with: event); return }
        finishCapture(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturing, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        finishCapture(with: event)
        return true
    }

    private func finishCapture(with event: NSEvent) {
        capturing = false
        contentTintColor = nil
        if Int(event.keyCode) == kVK_Escape {
            title = idleTitle
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.rawValue & placementModifierMask
        onCapture?(Int(event.keyCode), mods)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        capturing = false
        contentTintColor = nil
        title = idleTitle
        return super.resignFirstResponder()
    }
}

// MARK: - Grid region picker

final class PlacementGridPickerView: NSView {

    var grid = PlacementGrid.default {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var placement: GridPlacement? { didSet { needsDisplay = true } }
    var otherPlacements: [GridPlacement] = [] { didSet { needsDisplay = true } }
    var isEditable = true { didSet { needsDisplay = true } }
    var onChange: ((GridPlacement) -> Void)?

    /// Width:height the picker draws at. It stands in for the screen, so it
    /// keeps a display-like ratio rather than making the grid cells square.
    static let screenAspect: CGFloat = 16.0 / 9.0

    /// The largest box the picker will grow to when it has no width to fill.
    var maxSize = NSSize(width: 320, height: 320 / PlacementGridPickerView.screenAspect) {
        didSet { invalidateIntrinsicContentSize() }
    }

    private var anchorCell: (col: Int, row: Int)?
    private var hoverCell: (col: Int, row: Int)?

    override var isFlipped: Bool { true } // row 0 at the top, natural for editing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Largest screen-shaped box that fits inside `maxSize`.
    override var intrinsicContentSize: NSSize {
        let a = PlacementGridPickerView.screenAspect
        let byWidth = NSSize(width: maxSize.width, height: maxSize.width / a)
        return byWidth.height <= maxSize.height
            ? byWidth
            : NSSize(width: maxSize.height * a, height: maxSize.height)
    }

    /// Pin this view to a 16:9 box. Use with leading/trailing constraints so the
    /// picker fills the width it is given and derives its height.
    func activateScreenAspectConstraint() {
        heightAnchor.constraint(equalTo: widthAnchor,
                                multiplier: 1 / PlacementGridPickerView.screenAspect).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    // MARK: Geometry

    private var cellW: CGFloat { bounds.width / CGFloat(max(grid.cols, 1)) }
    private var cellH: CGFloat { bounds.height / CGFloat(max(grid.rows, 1)) }

    private func cell(at p: NSPoint) -> (col: Int, row: Int) {
        (min(max(Int(p.x / cellW), 0), grid.cols - 1),
         min(max(Int(p.y / cellH), 0), grid.rows - 1))
    }

    private func rect(for p: GridPlacement) -> NSRect {
        let n = p.normalized(in: grid)
        return NSRect(x: CGFloat(n.col) * cellW, y: CGFloat(n.row) * cellH,
                      width: CGFloat(n.colSpan) * cellW, height: CGFloat(n.rowSpan) * cellH)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard isEditable else { return }
        hoverCell = cell(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverCell = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        let c = cell(at: convert(event.locationInWindow, from: nil))
        anchorCell = c
        updateSelection(to: c)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEditable, anchorCell != nil else { return }
        updateSelection(to: cell(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        guard isEditable, anchorCell != nil else { return }
        updateSelection(to: cell(at: convert(event.locationInWindow, from: nil)))
        anchorCell = nil
        if let placement { onChange?(placement) }
    }

    private func updateSelection(to c: (col: Int, row: Int)) {
        guard let a = anchorCell else { return }
        var p = placement ?? GridPlacement(col: 0, row: 0, colSpan: 1, rowSpan: 1)
        p.col = min(a.col, c.col)
        p.row = min(a.row, c.row)
        p.colSpan = abs(a.col - c.col) + 1
        p.rowSpan = abs(a.row - c.row) + 1
        placement = p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        (isEditable ? NSColor.textBackgroundColor : NSColor.windowBackgroundColor).setFill()
        bounds.fill()

        if isEditable, let h = hoverCell {
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSRect(x: CGFloat(h.col) * cellW, y: CGFloat(h.row) * cellH, width: cellW, height: cellH).fill()
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for c in 0...grid.cols {
            let x = CGFloat(c) * cellW
            lines.move(to: NSPoint(x: x, y: 0)); lines.line(to: NSPoint(x: x, y: bounds.height))
        }
        for r in 0...grid.rows {
            let y = CGFloat(r) * cellH
            lines.move(to: NSPoint(x: 0, y: y)); lines.line(to: NSPoint(x: bounds.width, y: y))
        }
        lines.stroke()

        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
        for other in otherPlacements {
            NSBezierPath(roundedRect: rect(for: other).insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        }

        if let placement {
            let r = rect(for: placement).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else if isEditable {
            let text = NSLocalizedString("Drag to choose a region", tableName: "Main", value: "Drag to choose a region", comment: "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                    withAttributes: attrs)
        }
    }
}

// MARK: - Multi-window layouts editor

/// Self-contained editor for `PlacementKeymap.layouts`. Left: a table of
/// layouts. Right: key + label + a table of slots (app → region), each slot
/// edited with an app picker and a reused grid picker.
final class LayoutsPaneView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private var keymap = Defaults.placementKeymap.typedValue ?? .empty {
        didSet { Defaults.placementKeymap.typedValue = keymap }
    }

    private let layoutsTable = DeletableTableView()
    private lazy var layoutAddRemove = makeAddRemove(target: self, action: #selector(layoutAddRemoveChanged))
    private let keyButton = KeyCaptureButton()
    private let labelField = NSTextField()
    private let slotsTable = DeletableTableView()
    private lazy var slotAddRemove = makeAddRemove(target: self, action: #selector(slotAddRemoveChanged))
    private let appPopup = NSPopUpButton()
    private let picker = PlacementGridPickerView()

    private let layoutsEmptyLabel = emptyStateLabel(
        NSLocalizedString("No layouts yet — click + to create one.", tableName: "Main", value: "No layouts yet — click + to create one.", comment: ""))
    private let slotsEmptyLabel = emptyStateLabel(
        NSLocalizedString("Add a window for each app this layout arranges.", tableName: "Main", value: "Add a window for each app this layout arranges.", comment: ""))
    private let slotHintLabel = emptyStateLabel(
        NSLocalizedString("Select a window above, or click + to add one.", tableName: "Main", value: "Select a window above, or click + to add one.", comment: ""))
    /// The tinted block that groups the app picker + grid for the selected slot.
    private let slotEditorBox = TintedGroupView()
    /// Stack inside `slotEditorBox`; collapses when its arranged views hide.
    private let slotEditorStack = NSStackView()

    /// Shown when this layout's key is already spoken for. Lives in a stack with
    /// detachesHiddenViews, so hiding it closes the gap rather than leaving one.
    private let conflictLabel = NSTextField(labelWithString: "")

    /// Set when a new layout has just been added: its key should be captured as
    /// soon as the editor has finished rebuilding.
    private var armKeyAfterRefresh = false

    /// Same idea for a new window slot, whose one required value is the app.
    private var focusAppAfterRefresh = false

    /// bundleId per popup item index (parallel to `appPopup` menu items).
    private var appItemBundleIds: [String?] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: selection

    private var selLayoutIndex: Int? { layoutsTable.selectedRow >= 0 ? layoutsTable.selectedRow : nil }
    private var selSlotIndex: Int? { slotsTable.selectedRow >= 0 ? slotsTable.selectedRow : nil }
    private var selLayout: WindowLayout? { selLayoutIndex.flatMap { keymap.layouts.indices.contains($0) ? keymap.layouts[$0] : nil } }

    // MARK: build

    private func build() {
        // ---- Left card: the list of layouts --------------------------------
        let layScroll = styledScroll(wrapping: layoutsTable, columns: [
            ("key", NSLocalizedString("Key", tableName: "Main", value: "Key", comment: ""), 50),
            ("label", NSLocalizedString("Label", tableName: "Main", value: "Label", comment: ""), 96),
            ("count", NSLocalizedString("Windows", tableName: "Main", value: "Windows", comment: ""), 66),
        ])
        layoutsTable.dataSource = self
        layoutsTable.delegate = self
        layoutsTable.target = self
        layoutsTable.doubleAction = #selector(captureKeyForSelectedLayout)
        layoutsTable.onDelete = { [weak self] in self?.removeSelectedLayout() }

        let leftContent = NSView()
        leftContent.translatesAutoresizingMaskIntoConstraints = false
        for v in [layScroll, layoutsEmptyLabel, layoutAddRemove] {
            v.translatesAutoresizingMaskIntoConstraints = false
            leftContent.addSubview(v)
        }
        NSLayoutConstraint.activate([
            layScroll.topAnchor.constraint(equalTo: leftContent.topAnchor),
            layScroll.leadingAnchor.constraint(equalTo: leftContent.leadingAnchor),
            layScroll.trailingAnchor.constraint(equalTo: leftContent.trailingAnchor),
            layScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            layoutsEmptyLabel.centerXAnchor.constraint(equalTo: layScroll.centerXAnchor),
            layoutsEmptyLabel.centerYAnchor.constraint(equalTo: layScroll.centerYAnchor),
            layoutsEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: layScroll.widthAnchor, constant: -24),
            layoutAddRemove.topAnchor.constraint(equalTo: layScroll.bottomAnchor, constant: 6),
            layoutAddRemove.leadingAnchor.constraint(equalTo: leftContent.leadingAnchor),
            layoutAddRemove.bottomAnchor.constraint(equalTo: leftContent.bottomAnchor),
        ])

        // ---- Right card: the selected layout ------------------------------
        keyButton.onCapture = { [weak self] code, mods in self?.keyCaptured(code, mods) }
        labelField.placeholderString = NSLocalizedString("optional name", tableName: "Main", value: "optional name", comment: "")
        labelField.target = self; labelField.action = #selector(labelChanged)
        commitOnEndEditing(labelField)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let slotScroll = styledScroll(wrapping: slotsTable, columns: [
            ("app", NSLocalizedString("App", tableName: "Main", value: "App", comment: ""), 160),
            ("region", NSLocalizedString("Region", tableName: "Main", value: "Region", comment: ""), 150),
        ])
        slotsTable.dataSource = self
        slotsTable.delegate = self
        slotsTable.onDelete = { [weak self] in self?.removeSelectedSlot() }

        appPopup.target = self; appPopup.action = #selector(appChanged)
        appPopup.translatesAutoresizingMaskIntoConstraints = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] p in self?.pickerChanged(p) }
        picker.activateScreenAspectConstraint()

        // The tinted "Selected window" block. Its contents live in a stack view
        // so hiding them (nothing selected) collapses the block instead of
        // leaving a tall empty slab.
        slotEditorBox.wantsLayer = true
        slotEditorBox.translatesAutoresizingMaskIntoConstraints = false
        let appRow = hStack([rightLabel(NSLocalizedString("App", tableName: "Main", value: "App", comment: "")), appPopup, uiSpacer()])
        slotEditorStack.orientation = .vertical
        slotEditorStack.alignment = .centerX
        slotEditorStack.spacing = 8
        slotEditorStack.detachesHiddenViews = true
        slotEditorStack.translatesAutoresizingMaskIntoConstraints = false
        slotEditorStack.addArrangedSubview(appRow)
        slotEditorStack.addArrangedSubview(picker)

        for v in [slotEditorStack, slotHintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slotEditorBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            slotEditorStack.topAnchor.constraint(equalTo: slotEditorBox.topAnchor, constant: 10),
            slotEditorStack.leadingAnchor.constraint(equalTo: slotEditorBox.leadingAnchor, constant: 10),
            slotEditorStack.trailingAnchor.constraint(equalTo: slotEditorBox.trailingAnchor, constant: -10),
            slotEditorStack.bottomAnchor.constraint(equalTo: slotEditorBox.bottomAnchor, constant: -10),
            appRow.leadingAnchor.constraint(equalTo: slotEditorStack.leadingAnchor),
            appRow.trailingAnchor.constraint(equalTo: slotEditorStack.trailingAnchor),
            picker.leadingAnchor.constraint(equalTo: slotEditorStack.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: slotEditorStack.trailingAnchor),
            slotEditorBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 74),
            slotHintLabel.centerXAnchor.constraint(equalTo: slotEditorBox.centerXAnchor),
            slotHintLabel.centerYAnchor.constraint(equalTo: slotEditorBox.centerYAnchor),
            slotHintLabel.widthAnchor.constraint(lessThanOrEqualTo: slotEditorBox.widthAnchor, constant: -24),
        ])

        let keyRow = hStack([
            rightLabel(NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")), keyButton,
            rightLabel(NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")), labelField,
        ], spacing: 8)

        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed
        conflictLabel.lineBreakMode = .byWordWrapping
        conflictLabel.maximumNumberOfLines = 2
        conflictLabel.isHidden = true

        let keyBlock = NSStackView(views: [keyRow, conflictLabel])
        keyBlock.orientation = .vertical
        keyBlock.alignment = .leading
        keyBlock.spacing = 6
        keyBlock.detachesHiddenViews = true

        let windowsHeader = NSTextField(labelWithString: NSLocalizedString("Windows", tableName: "Main", value: "Windows", comment: ""))
        windowsHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        windowsHeader.textColor = .secondaryLabelColor
        windowsHeader.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: NSLocalizedString("Bind a key, then add a window per app. Pressing the key in the overlay arranges them all.", tableName: "Main", value: "Bind a key, then add a window per app. Pressing the key in the overlay arranges them all.", comment: ""))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let rightContent = NSView()
        rightContent.translatesAutoresizingMaskIntoConstraints = false
        for v in [keyBlock, windowsHeader, slotScroll, slotsEmptyLabel, slotAddRemove, slotEditorBox, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            rightContent.addSubview(v)
        }
        NSLayoutConstraint.activate([
            keyBlock.topAnchor.constraint(equalTo: rightContent.topAnchor),
            keyBlock.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            keyBlock.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),
            conflictLabel.widthAnchor.constraint(lessThanOrEqualTo: keyBlock.widthAnchor),

            windowsHeader.topAnchor.constraint(equalTo: keyBlock.bottomAnchor, constant: 14),
            windowsHeader.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),

            slotScroll.topAnchor.constraint(equalTo: windowsHeader.bottomAnchor, constant: 4),
            slotScroll.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            slotScroll.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),
            slotScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            slotsEmptyLabel.centerXAnchor.constraint(equalTo: slotScroll.centerXAnchor),
            slotsEmptyLabel.centerYAnchor.constraint(equalTo: slotScroll.centerYAnchor),
            slotsEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: slotScroll.widthAnchor, constant: -24),

            slotAddRemove.topAnchor.constraint(equalTo: slotScroll.bottomAnchor, constant: 6),
            slotAddRemove.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),

            slotEditorBox.topAnchor.constraint(equalTo: slotAddRemove.bottomAnchor, constant: 10),
            slotEditorBox.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            slotEditorBox.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),

            hint.topAnchor.constraint(equalTo: slotEditorBox.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: rightContent.bottomAnchor),
        ])

        // ---- Cards --------------------------------------------------------
        // Both fill the pane height (the Placements sub-pane is the taller of
        // the two and sets the window size), so the tables absorb the slack
        // instead of leaving a blank band under the cards.
        let leftCard = titledCard(NSLocalizedString("Layouts", tableName: "Main", value: "Layouts", comment: ""), leftContent, fillsHeight: true)
        let rightCard = titledCard(NSLocalizedString("Layout", tableName: "Main", value: "Layout", comment: ""), rightContent, fillsHeight: true)

        for v in [leftCard, rightCard] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // Same 50/50 split as the Placements sub-pane so the columns don't move
        // when you toggle between them.
        NSLayoutConstraint.activate([
            leftCard.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            leftCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PlacementUI.outerMargin),

            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: PlacementUI.columnGutter),
            rightCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PlacementUI.outerMargin),
            rightCard.widthAnchor.constraint(equalTo: leftCard.widthAnchor),

            leftCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            rightCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    // MARK: reload / refresh

    func reload() {
        keymap = Defaults.placementKeymap.typedValue ?? .empty
        picker.grid = keymap.grid
        rebuildAppPopup()
        layoutsTable.reloadData()
        layoutsEmptyLabel.isHidden = !keymap.layouts.isEmpty
        if selLayoutIndex == nil, !keymap.layouts.isEmpty {
            layoutsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        slotsTable.reloadData()
        refreshDetail()
    }

    /// Redraw every cell without touching the selection. `reloadData()` drops
    /// the selection; this does not, so it is what a content-only edit wants.
    /// Only valid while the row count is unchanged.
    private func reloadCells(_ table: NSTableView) {
        let rows = table.numberOfRows, cols = table.numberOfColumns
        guard rows > 0, cols > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows),
                         columnIndexes: IndexSet(integersIn: 0..<cols))
    }

    /// Full reload for when the row count may have changed, putting the
    /// selection back afterwards so an edit does not silently deselect.
    /// Re-selecting posts a selection notification, which is safe for the slots
    /// table (its handler does not reload) but must never be used on the
    /// layouts table, whose handler rebuilds the slots table from scratch.
    private func reloadPreservingSelection(_ table: NSTableView) {
        let row = table.selectedRow
        table.reloadData()
        guard row >= 0, row < table.numberOfRows else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func refreshDetail() {
        let layout = selLayout
        let on = layout != nil
        keyButton.isEnabled = on
        labelField.isEnabled = on
        slotAddRemove.setEnabled(on, forSegment: 0)
        slotAddRemove.setEnabled(selSlotIndex != nil, forSegment: 1)
        layoutAddRemove.setEnabled(selLayoutIndex != nil, forSegment: 1)

        keyButton.setKey(keyCode: layout?.keyCode ?? PlacementBinding.unassignedKeyCode,
                         modifierFlags: layout?.modifierFlags ?? 0)
        labelField.stringValue = layout?.label ?? ""
        updateConflictLabel()
        // Deliberately no slotsTable.reloadData() here. refreshDetail() renders
        // the detail pane from the current selection and is what
        // tableViewSelectionDidChange calls, so reloading the slots table from
        // inside it would clear the very selection that triggered it - the
        // editor could then never open. Reloads live with the data changes
        // instead: see reloadPreservingSelection and the layout-identity paths.
        slotsEmptyLabel.isHidden = !(layout?.slots.isEmpty ?? true)

        let slot = currentSlot
        appPopup.isEnabled = slot != nil
        picker.isEditable = slot != nil
        picker.placement = slot?.placement
        // Collapse the whole block to its hint when nothing is selected.
        slotHintLabel.isHidden = slot != nil
        slotEditorStack.arrangedSubviews.forEach { $0.isHidden = slot == nil }
        if let bid = slot?.appBundleId, let idx = appItemBundleIds.firstIndex(of: bid) {
            appPopup.selectItem(at: idx)
        }
        picker.needsDisplay = true
    }

    private var currentSlot: LayoutSlot? {
        guard let li = selLayoutIndex, let si = selSlotIndex,
              keymap.layouts.indices.contains(li), keymap.layouts[li].slots.indices.contains(si)
        else { return nil }
        return keymap.layouts[li].slots[si]
    }

    private func mutateLayout(_ f: (inout WindowLayout) -> Void) {
        guard let li = selLayoutIndex, keymap.layouts.indices.contains(li) else { return }
        var l = keymap.layouts[li]; f(&l); keymap.layouts[li] = l
        // The layout count is unchanged, so redraw its cells in place: a full
        // reload here would re-select and fire the layouts handler, which
        // rebuilds the slots table and would drop the user's slot selection.
        reloadCells(layoutsTable)
        // The slot count may have changed (add/remove), so this one needs a
        // real reload, with the selection restored when it is still valid.
        reloadPreservingSelection(slotsTable)
    }
    private func mutateSlot(_ f: (inout LayoutSlot) -> Void) {
        guard let li = selLayoutIndex, let si = selSlotIndex,
              keymap.layouts.indices.contains(li), keymap.layouts[li].slots.indices.contains(si) else { return }
        var l = keymap.layouts[li]; var s = l.slots[si]; f(&s); l.slots[si] = s; keymap.layouts[li] = l
        // Editing a slot changes cell text only - no row counts move - so both
        // tables can redraw in place and the selection survives untouched.
        reloadCells(slotsTable)
        reloadCells(layoutsTable)
    }

    // MARK: actions

    @objc private func layoutAddRemoveChanged() {
        if layoutAddRemove.selectedSegment == 0 {
            keymap.layouts.append(WindowLayout(label: ""))
            layoutsTable.reloadData()
            layoutsTable.selectRowIndexes(IndexSet(integer: keymap.layouts.count - 1), byExtendingSelection: false)
            armKeyAfterRefresh = true
        } else {
            removeSelectedLayout()
            return
        }
        refreshDetail()
        // refreshDetail resets the button, so arm it only once that has run.
        if armKeyAfterRefresh {
            armKeyAfterRefresh = false
            keyButton.armCapture()
        }
    }

    private func removeSelectedLayout() {
        guard let li = selLayoutIndex else { return }
        keymap.layouts.remove(at: li)
        layoutsTable.reloadData()
        if !keymap.layouts.isEmpty {
            layoutsTable.selectRowIndexes(IndexSet(integer: min(li, keymap.layouts.count - 1)), byExtendingSelection: false)
        }
        // Removing the last layout selects nothing, so no selection change
        // fires to rebuild the slots table - clear it here.
        slotsTable.reloadData()
        refreshDetail()
    }
    @objc private func slotAddRemoveChanged() {
        if slotAddRemove.selectedSegment == 0 {
            let g = keymap.grid
            mutateLayout { $0.slots.append(LayoutSlot(placement: GridPlacement(col: 0, row: 0, colSpan: g.cols, rowSpan: g.rows))) }
            slotsTable.selectRowIndexes(IndexSet(integer: (selLayout?.slots.count ?? 1) - 1), byExtendingSelection: false)
            focusAppAfterRefresh = true
        } else {
            removeSelectedSlot()
            return
        }
        refreshDetail()
        // refreshDetail re-enables the popup, so take focus only once it has run.
        if focusAppAfterRefresh {
            focusAppAfterRefresh = false
            window?.makeFirstResponder(appPopup)
        }
    }

    private func removeSelectedSlot() {
        guard let si = selSlotIndex else { return }
        mutateLayout { if $0.slots.indices.contains(si) { $0.slots.remove(at: si) } }
        // The removed row's index is gone; keep a neighbour selected so the
        // editor stays open on something rather than collapsing.
        let remaining = selLayout?.slots.count ?? 0
        if remaining > 0 {
            slotsTable.selectRowIndexes(IndexSet(integer: min(si, remaining - 1)), byExtendingSelection: false)
        }
        refreshDetail()
    }
    /// A layout sharing a key with a placement never fires - handleKey resolves
    /// placements first - so say so where the key is set rather than leaving a
    /// dead binding in the list.
    private func updateConflictLabel() {
        guard let l = selLayout, l.isAssigned,
              let holder = keymap.holder(ofKeyCode: l.keyCode, modifierFlags: l.modifierFlags, excluding: l.id)
        else {
            conflictLabel.stringValue = ""
            conflictLabel.isHidden = true
            return
        }
        conflictLabel.stringValue = placementConflictMessage(keyCode: l.keyCode,
                                                             modifierFlags: l.modifierFlags,
                                                             holder: holder)
        conflictLabel.isHidden = false
    }

    /// Matches the Placements table: double-clicking a layout sets its key.
    @objc private func captureKeyForSelectedLayout() { keyButton.armCapture() }

    private func keyCaptured(_ code: Int, _ mods: UInt) {
        mutateLayout { $0.keyCode = code; $0.modifierFlags = mods & placementModifierMask }
        keyButton.setKey(keyCode: code, modifierFlags: mods)
        updateConflictLabel()
    }
    @objc private func labelChanged() { mutateLayout { $0.label = labelField.stringValue } }
    @objc private func appChanged() {
        let idx = appPopup.indexOfSelectedItem
        if idx == appItemBundleIds.count { // "Choose…"
            chooseApp()
            return
        }
        guard let bid = appItemBundleIds[safe: idx] ?? nil else { return }
        mutateSlot { $0.appBundleId = bid }
    }
    private func pickerChanged(_ p: GridPlacement) {
        mutateSlot { $0.placement.col = p.col; $0.placement.row = p.row; $0.placement.colSpan = p.colSpan; $0.placement.rowSpan = p.rowSpan }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url,
                  let bid = Bundle(url: url)?.bundleIdentifier, let self else { return }
            if !self.appItemBundleIds.contains(bid) {
                self.appPopup.insertItem(withTitle: url.deletingPathExtension().lastPathComponent, at: 0)
                self.appItemBundleIds.insert(bid, at: 0)
            }
            self.mutateSlot { $0.appBundleId = bid }
            self.refreshDetail()
        }
    }

    private func rebuildAppPopup() {
        var pairs: [(String, String)] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
        // Include any app a slot already references even if it isn't running,
        // resolved to its real name - a layout built around a closed app read
        // as "com.apple.dt.Xcode" before.
        for l in keymap.layouts { for s in l.slots where !s.appBundleId.isEmpty && !pairs.contains(where: { $0.0 == s.appBundleId }) {
            pairs.append((s.appBundleId, PlacementModeController.displayName(forBundleId: s.appBundleId)))
        } }
        pairs = Array(Set(pairs.map { $0.0 })).compactMap { bid in pairs.first { $0.0 == bid } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        appPopup.removeAllItems()
        appItemBundleIds = []
        for (bid, name) in pairs { appPopup.addItem(withTitle: name); appItemBundleIds.append(bid) }
        appPopup.addItem(withTitle: NSLocalizedString("Choose Application…", tableName: "Main", value: "Choose Application…", comment: ""))
    }

    // MARK: table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === layoutsTable ? keymap.layouts.count : (selLayout?.slots.count ?? 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        if tableView === layoutsTable {
            let l = keymap.layouts[row]
            switch id {
            case "key": text = l.isAssigned ? keyCapString(l.keyCode, l.modifierFlags) : "—"
            case "label": text = l.label
            default: text = "\(l.slots.count)"
            }
        } else {
            guard let l = selLayout, l.slots.indices.contains(row) else { return nil }
            let s = l.slots[row]
            switch id {
            case "app": text = appName(for: s.appBundleId)
            default: text = s.placement.regionDescription(in: keymap.grid)
            }
        }
        let ident = NSUserInterfaceItemIdentifier("c_\(id)")
        let cell = (tableView.makeView(withIdentifier: ident, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = tableCellTextField(mono: id == "key")
            c.addSubview(tf); c.textField = tf; c.identifier = ident
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
        // A different layout means a different set of slots, so that is the one
        // selection change that has to rebuild the slots table. A change in the
        // slots table itself must not reload it - that is the bug this avoids.
        if notification.object as? NSTableView === layoutsTable {
            slotsTable.reloadData()
        }
        refreshDetail()
    }

    // MARK: helpers

    private func appName(for bundleId: String) -> String {
        if bundleId.isEmpty { return NSLocalizedString("(choose an app)", tableName: "Main", value: "(choose an app)", comment: "") }
        if let idx = appItemBundleIds.firstIndex(of: bundleId) { return appPopup.item(at: idx)?.title ?? bundleId }
        return bundleId
    }
    private func keyCapString(_ code: Int, _ mods: UInt) -> String {
        let s = MASShortcut(keyCode: code, modifierFlags: NSEvent.ModifierFlags(rawValue: mods))
        return [s.modifierFlagsString, s.keyCodeString].compactMap { $0 }.joined()
    }
}

// MARK: - Layouts tab

/// Hosts `LayoutsPaneView` as the "Layouts" tab of Snappy Settings. Layouts and
/// Placements are siblings — a layout arranges several windows at once, a
/// placement moves the front one — so neither is nested under the other.
final class LayoutsConfigViewController: NSViewController {

    private let pane = LayoutsPaneView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: SettingsTabViewController.paneWidth, height: 520))
        pane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane)
        NSLayoutConstraint.activate([
            // See PlacementConfigViewController: preferredContentSize drops a
            // width constraint on the pane view, so the content asserts it.
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsTabViewController.paneWidth),
            pane.topAnchor.constraint(equalTo: view.topAnchor, constant: PlacementUI.paneTopInset),
            pane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Pick up placements/grid edits made on the other tab, or an import.
        pane.reload()
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        if abs(preferredContentSize.height - fit.height) > 0.5 || abs(preferredContentSize.width - fit.width) > 0.5 {
            preferredContentSize = fit
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
