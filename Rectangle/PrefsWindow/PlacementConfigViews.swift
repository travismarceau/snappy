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
    private var displayTitle = NSLocalizedString("Press a key…", tableName: "Main", value: "Press a key…", comment: "")

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
        title = displayTitle
        target = self
        action = #selector(beginCapture)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    override var acceptsFirstResponder: Bool { true }

    func setKey(keyCode: Int, modifierFlags: UInt) {
        capturing = false
        if keyCode < 0 {
            displayTitle = NSLocalizedString("Press a key…", tableName: "Main", value: "Press a key…", comment: "")
        } else {
            let s = MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
            displayTitle = [s.modifierFlagsString, s.keyCodeString].compactMap { $0 }.joined()
            if displayTitle.isEmpty { displayTitle = "?" }
        }
        title = displayTitle
    }

    @objc private func beginCapture() {
        guard isEnabled else { return }
        capturing = true
        title = NSLocalizedString("Type key…", tableName: "Main", value: "Type key…", comment: "")
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard capturing else { super.keyDown(with: event); return }
        finishCapture(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Modified combos (⌘…, ⌥…) arrive here rather than through keyDown.
        guard capturing, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        finishCapture(with: event)
        return true
    }

    private func finishCapture(with event: NSEvent) {
        capturing = false
        if Int(event.keyCode) == kVK_Escape {
            title = displayTitle
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.rawValue & placementModifierMask
        onCapture?(Int(event.keyCode), mods)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        capturing = false
        title = displayTitle
        return super.resignFirstResponder()
    }
}

// MARK: - Grid region picker

final class PlacementGridPickerView: NSView {

    var grid = PlacementGrid.default { didSet { needsDisplay = true } }
    var placement: GridPlacement? { didSet { needsDisplay = true } }
    var otherPlacements: [GridPlacement] = [] { didSet { needsDisplay = true } }
    var isEditable = true
    var onChange: ((GridPlacement) -> Void)?

    private var anchorCell: (col: Int, row: Int)?

    override var isFlipped: Bool { true } // row 0 at the top, natural for editing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 4
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 240) }

    // MARK: Geometry

    private var cellWidth: CGFloat { bounds.width / CGFloat(max(grid.cols, 1)) }
    private var cellHeight: CGFloat { bounds.height / CGFloat(max(grid.rows, 1)) }

    private func cell(at point: NSPoint) -> (col: Int, row: Int) {
        let col = min(max(Int(point.x / cellWidth), 0), grid.cols - 1)
        let row = min(max(Int(point.y / cellHeight), 0), grid.rows - 1)
        return (col, row)
    }

    private func rect(for p: GridPlacement) -> NSRect {
        let n = p.normalized(in: grid)
        return NSRect(x: CGFloat(n.col) * cellWidth,
                      y: CGFloat(n.row) * cellHeight,
                      width: CGFloat(n.colSpan) * cellWidth,
                      height: CGFloat(n.rowSpan) * cellHeight)
    }

    // MARK: Mouse

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
        let col = min(a.col, c.col)
        let row = min(a.row, c.row)
        let colSpan = abs(a.col - c.col) + 1
        let rowSpan = abs(a.row - c.row) + 1
        var p = placement ?? GridPlacement(col: col, row: row, colSpan: colSpan, rowSpan: rowSpan)
        p.col = col; p.row = row; p.colSpan = colSpan; p.rowSpan = rowSpan
        placement = p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // Cell grid
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for c in 0...self.grid.cols {
            let x = CGFloat(c) * cellWidth
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: bounds.height))
        }
        for r in 0...self.grid.rows {
            let y = CGFloat(r) * cellHeight
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.stroke()

        // Other placements (faint)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        for other in otherPlacements {
            rect(for: other).insetBy(dx: 1, dy: 1).fill()
        }

        // Current selection
        if let placement {
            let r = rect(for: placement).insetBy(dx: 1, dy: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
            r.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
