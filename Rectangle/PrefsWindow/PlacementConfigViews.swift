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

    var grid = PlacementGrid.default { didSet { needsDisplay = true } }
    var placement: GridPlacement? { didSet { needsDisplay = true } }
    var otherPlacements: [GridPlacement] = [] { didSet { needsDisplay = true } }
    var isEditable = true { didSet { needsDisplay = true } }
    var onChange: ((GridPlacement) -> Void)?

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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 168) }

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

    private let layoutsTable = NSTableView()
    private let layoutAddRemove = NSSegmentedControl()
    private let keyButton = KeyCaptureButton()
    private let labelField = NSTextField()
    private let slotsTable = NSTableView()
    private let slotAddRemove = NSSegmentedControl()
    private let appPopup = NSPopUpButton()
    private let picker = PlacementGridPickerView()
    private let hint = NSTextField(labelWithString: "")

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
        let layScroll = tableInScroll(layoutsTable, columns: [
            ("key", NSLocalizedString("Key", tableName: "Main", value: "Key", comment: ""), 56),
            ("label", NSLocalizedString("Label", tableName: "Main", value: "Label", comment: ""), 110),
            ("count", NSLocalizedString("Windows", tableName: "Main", value: "Windows", comment: ""), 70),
        ])
        layoutsTable.dataSource = self
        layoutsTable.delegate = self

        segmentedAddRemove(layoutAddRemove, action: #selector(layoutAddRemoveChanged))

        let left = column([layScroll, row([layoutAddRemove, spacerV()])], width: 244)

        // Right column
        keyButton.onCapture = { [weak self] code, mods in self?.keyCaptured(code, mods) }
        labelField.placeholderString = NSLocalizedString("optional name", tableName: "Main", value: "optional name", comment: "")
        labelField.target = self; labelField.action = #selector(labelChanged)
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let slotScroll = tableInScroll(slotsTable, columns: [
            ("app", NSLocalizedString("App", tableName: "Main", value: "App", comment: ""), 150),
            ("region", NSLocalizedString("Region", tableName: "Main", value: "Region", comment: ""), 120),
        ])
        slotsTable.dataSource = self
        slotsTable.delegate = self
        segmentedAddRemove(slotAddRemove, action: #selector(slotAddRemoveChanged))

        appPopup.target = self; appPopup.action = #selector(appChanged)
        appPopup.translatesAutoresizingMaskIntoConstraints = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] p in self?.pickerChanged(p) }

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = NSLocalizedString("Bind a key, then add a window per app. Pressing the key in the overlay arranges them all.", tableName: "Main", value: "Bind a key, then add a window per app. Pressing the key in the overlay arranges them all.", comment: "")
        hint.translatesAutoresizingMaskIntoConstraints = false

        let keyRow = row([label(NSLocalizedString("Key", tableName: "Main", value: "Key", comment: "")), keyButton,
                          label(NSLocalizedString("Label", tableName: "Main", value: "Label", comment: "")), labelField])
        let slotButtons = row([slotAddRemove, spacerV()])
        let slotDetail = row([label(NSLocalizedString("App", tableName: "Main", value: "App", comment: "")), appPopup])
        let right = NSStackView(views: [keyRow, slotScroll, slotButtons, slotDetail, picker, hint])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slotScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            slotScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            picker.heightAnchor.constraint(equalToConstant: 150),
            picker.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            labelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        addSubview(left); addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            right.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 20),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            right.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
        ])
    }

    // MARK: reload / refresh

    func reload() {
        keymap = Defaults.placementKeymap.typedValue ?? .empty
        picker.grid = keymap.grid
        rebuildAppPopup()
        layoutsTable.reloadData()
        if selLayoutIndex == nil, !keymap.layouts.isEmpty {
            layoutsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        refreshDetail()
    }

    private func refreshDetail() {
        let layout = selLayout
        let on = layout != nil
        keyButton.isEnabled = on
        labelField.isEnabled = on
        slotAddRemove.setEnabled(on, forSegment: 0)
        layoutAddRemove.setEnabled(selLayoutIndex != nil, forSegment: 1)

        keyButton.setKey(keyCode: layout?.keyCode ?? PlacementBinding.unassignedKeyCode,
                         modifierFlags: layout?.modifierFlags ?? 0)
        labelField.stringValue = layout?.label ?? ""
        slotsTable.reloadData()

        let slot = currentSlot
        appPopup.isEnabled = slot != nil
        picker.isEditable = slot != nil
        picker.placement = slot?.placement
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
        layoutsTable.reloadData()
        slotsTable.reloadData()
    }
    private func mutateSlot(_ f: (inout LayoutSlot) -> Void) {
        guard let li = selLayoutIndex, let si = selSlotIndex,
              keymap.layouts.indices.contains(li), keymap.layouts[li].slots.indices.contains(si) else { return }
        var l = keymap.layouts[li]; var s = l.slots[si]; f(&s); l.slots[si] = s; keymap.layouts[li] = l
        slotsTable.reloadData()
        layoutsTable.reloadData()
    }

    // MARK: actions

    @objc private func layoutAddRemoveChanged() {
        if layoutAddRemove.selectedSegment == 0 {
            keymap.layouts.append(WindowLayout(label: ""))
            layoutsTable.reloadData()
            layoutsTable.selectRowIndexes(IndexSet(integer: keymap.layouts.count - 1), byExtendingSelection: false)
            window?.makeFirstResponder(keyButton)
        } else if let li = selLayoutIndex {
            keymap.layouts.remove(at: li)
            layoutsTable.reloadData()
            if !keymap.layouts.isEmpty {
                layoutsTable.selectRowIndexes(IndexSet(integer: min(li, keymap.layouts.count - 1)), byExtendingSelection: false)
            }
        }
        refreshDetail()
    }
    @objc private func slotAddRemoveChanged() {
        if slotAddRemove.selectedSegment == 0 {
            let g = keymap.grid
            mutateLayout { $0.slots.append(LayoutSlot(placement: GridPlacement(col: 0, row: 0, colSpan: g.cols, rowSpan: g.rows))) }
            slotsTable.selectRowIndexes(IndexSet(integer: (selLayout?.slots.count ?? 1) - 1), byExtendingSelection: false)
        } else if let si = selSlotIndex {
            mutateLayout { if $0.slots.indices.contains(si) { $0.slots.remove(at: si) } }
        }
        refreshDetail()
    }
    private func keyCaptured(_ code: Int, _ mods: UInt) {
        mutateLayout { $0.keyCode = code; $0.modifierFlags = mods & placementModifierMask }
        keyButton.setKey(keyCode: code, modifierFlags: mods)
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
        // include any app referenced by an existing slot even if not running
        for l in keymap.layouts { for s in l.slots where !s.appBundleId.isEmpty && !pairs.contains(where: { $0.0 == s.appBundleId }) {
            pairs.append((s.appBundleId, s.appBundleId))
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
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = id == "key" ? .monospacedSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
            c.addSubview(tf); c.textField = tf; c.identifier = ident
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

    func tableViewSelectionDidChange(_ notification: Notification) { refreshDetail() }

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
    private func label(_ s: String) -> NSTextField {
        let tf = NSTextField(labelWithString: s)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentHuggingPriority(.required, for: .horizontal)
        return tf
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 8; s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false; return s
    }
    private func column(_ views: [NSView], width: CGFloat) -> NSView {
        let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = 6; s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        return s
    }
    private func spacerV() -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v
    }
    private func segmentedAddRemove(_ c: NSSegmentedControl, action: Selector) {
        c.segmentStyle = .separated; c.trackingMode = .momentary; c.segmentCount = 2
        c.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        c.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        c.setWidth(30, forSegment: 0); c.setWidth(30, forSegment: 1)
        c.target = self; c.action = action
        c.translatesAutoresizingMaskIntoConstraints = false
    }
    private func tableInScroll(_ table: NSTableView, columns: [(String, String, CGFloat)]) -> NSScrollView {
        for (id, title, w) in columns {
            let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = w
            table.addTableColumn(col)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = false
        if #available(macOS 11, *) { table.style = .inset }
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .lineBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
