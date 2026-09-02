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
        layer?.cornerRadius = 8
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
