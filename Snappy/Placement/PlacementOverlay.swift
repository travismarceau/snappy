/// PlacementOverlay.swift
///
/// The grid-based placement panel: a small floating box, not a full-screen
/// wash.
///
/// It was a full-screen overlay first, on the reasoning that a pane covering the
/// screen is 1:1 with it, so the rectangle you drag is literally where the
/// window lands. True, and wrong in practice: a grid stretched over the whole
/// display is faint wherever your wallpaper is busy, it hides the windows you
/// are arranging, and the gesture spans the whole desk instead of an inch of
/// mouse travel. A compact panel keeps the whole grid within easy reach.
///
/// Being small also fixes the input. A full-screen pane has to be
/// click-through, so every click had to be intercepted by a CGEventTap -- which
/// needs Accessibility, and silently does nothing without it. A small panel is
/// an ordinary window that takes ordinary mouse events, so dragging works
/// whatever macOS thinks of our permissions.

import Cocoa
import MASShortcut

// MARK: - Key labels

/// The "⌃⌥A" text for a key binding. Shared by the panel's keycaps and its
/// layout legend so they can never drift apart.
enum PlacementKeyLabel {
    static func text(keyCode: Int, modifierFlags: UInt) -> String {
        guard keyCode >= 0 else { return "" }
        let shortcut = MASShortcut(keyCode: keyCode,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
        return [shortcut.modifierFlagsString, shortcut.keyCodeString].compactMap { $0 }.joined()
    }
}

// MARK: - Panel

final class PlacementOverlayPanel: NSPanel {

    /// The display this panel places onto, and the rect within it that the grid
    /// represents. The panel itself is a small box somewhere on that screen.
    let targetScreen: NSScreen
    let targetFrame: CGRect
    let keymap: PlacementKeymap

    private let panelView: PlacementPanelView

    /// Fired as a drag moves, and once when it is released.
    var onDragChanged: ((GridPlacement?) -> Void)?
    var onDragCommitted: ((GridPlacement) -> Void)?

    /// Panel chrome. The grid keeps the screen's aspect so a region drawn here
    /// has the proportions it will have on screen.
    private static let gridWidth: CGFloat = 300
    private static let padding: CGFloat = 12
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 20

    init(screen: NSScreen, frame: CGRect, keymap: PlacementKeymap, dragEnabled: Bool) {
        self.targetScreen = screen
        self.targetFrame = frame
        self.keymap = keymap

        let aspect = max(0.2, frame.width / max(frame.height, 1))
        let gridSize = NSSize(width: Self.gridWidth, height: (Self.gridWidth / aspect).rounded())
        let contentSize = NSSize(
            width: gridSize.width + Self.padding * 2,
            height: gridSize.height + Self.padding * 2 + Self.headerHeight + Self.footerHeight)

        panelView = PlacementPanelView(
            frame: NSRect(origin: .zero, size: contentSize),
            keymap: keymap,
            dragEnabled: dragEnabled,
            gridInsets: NSEdgeInsets(top: Self.padding + Self.headerHeight,
                                     left: Self.padding,
                                     bottom: Self.padding + Self.footerHeight,
                                     right: Self.padding))

        // Centred on the target area, biased slightly high the way a dialog is.
        let origin = NSPoint(x: (frame.midX - contentSize.width / 2).rounded(),
                             y: (frame.midY - contentSize.height / 2 + frame.height * 0.06).rounded())

        super.init(contentRect: NSRect(origin: origin, size: contentSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The whole point of the small panel: it takes its own mouse events.
        // With dragging disabled the pane is purely informational and must not
        // eat clicks intended for the window behind it.
        ignoresMouseEvents = !dragEnabled
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .stationary]

        contentView = panelView
        alphaValue = 0

        panelView.onDragChanged = { [weak self] p in self?.onDragChanged?(p) }
        panelView.onDragCommitted = { [weak self] p in self?.onDragCommitted?(p) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func matches(frame: CGRect, keymap: PlacementKeymap, dragEnabled: Bool) -> Bool {
        targetFrame == frame && self.keymap == keymap && panelView.dragEnabled == dragEnabled
    }

    func prepareForReuse() {
        panelView.reset()
        alphaValue = 0
    }

    /// Name the window being placed so the target stays clear. Without it
    /// a bare grid gives no clue which window is about to move.
    func setTarget(name: String?, icon: NSImage?) {
        panelView.setTarget(name: name, icon: icon)
    }

    func present() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            animator().alphaValue = 1
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Replaces the footer hint with something that has gone wrong. Dragging
    /// still works while this is showing; only the keys are affected.
    func setWarning(_ text: String?) { panelView.warning = text }

    func revealPlacements(animated: Bool) { panelView.revealPlacements(animated: animated) }
    func updateHover(_ cell: GridCell?)   { panelView.hoverCell = cell }
    func updateDrag(_ p: GridPlacement?)  { panelView.dragSelection = p }
    func clearDrag()                      { panelView.dragSelection = nil }
    func flash(placement: GridPlacement)  { panelView.flash(placement: placement) }
    func flash(layout: WindowLayout, outcome: PlacementModeController.LayoutOutcome) {
        panelView.flash(layout: layout, outcome: outcome)
    }
}

// MARK: - Panel view

final class PlacementPanelView: NSView {

    private let keymap: PlacementKeymap
    let dragEnabled: Bool
    private let gridInsets: NSEdgeInsets

    private var targetName: String?
    private var targetIcon: NSImage?
    private var placementsRevealed = false
    private var flashedPlacement: GridPlacement?
    private var flashedLayout: WindowLayout?
    private var flashedOutcome: PlacementModeController.LayoutOutcome?

    private var dragAnchor: GridCell?

    var onDragChanged: ((GridPlacement?) -> Void)?
    var onDragCommitted: ((GridPlacement) -> Void)?

    var warning: String? { didSet { if warning != oldValue { needsDisplay = true } } }
    var hoverCell: GridCell? { didSet { if hoverCell != oldValue { needsDisplay = true } } }
    var dragSelection: GridPlacement? { didSet { if dragSelection != oldValue { needsDisplay = true } } }

    init(frame: NSRect, keymap: PlacementKeymap, dragEnabled: Bool, gridInsets: NSEdgeInsets) {
        self.keymap = keymap
        self.dragEnabled = dragEnabled
        self.gridInsets = gridInsets
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    func reset() {
        warning = nil
        hoverCell = nil
        dragSelection = nil
        dragAnchor = nil
        placementsRevealed = false
        flashedPlacement = nil
        flashedLayout = nil
        flashedOutcome = nil
        needsDisplay = true
    }

    func setTarget(name: String?, icon: NSImage?) {
        targetName = name
        targetIcon = icon
        needsDisplay = true
    }

    func revealPlacements(animated: Bool) {
        guard !placementsRevealed else { return }
        placementsRevealed = true
        needsDisplay = true
    }

    func flash(placement: GridPlacement) {
        flashedPlacement = placement
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.flashedPlacement = nil; self?.needsDisplay = true
        }
    }

    func flash(layout: WindowLayout, outcome: PlacementModeController.LayoutOutcome) {
        flashedLayout = layout
        flashedOutcome = outcome
        needsDisplay = true
        let hold = outcome.isComplete ? 0.35 : 1.4
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.flashedLayout = nil; self?.flashedOutcome = nil; self?.needsDisplay = true
        }
    }

    // MARK: Geometry

    /// The rect the grid occupies inside the panel.
    private var gridRect: NSRect {
        NSRect(x: gridInsets.left,
               y: gridInsets.bottom,
               width: bounds.width - gridInsets.left - gridInsets.right,
               height: bounds.height - gridInsets.top - gridInsets.bottom)
    }

    private var geometry: PlacementGridGeometry {
        PlacementGridGeometry(bounds: gridRect, grid: keymap.grid, outerMargin: 0)
    }

    private func rect(for placement: GridPlacement) -> NSRect {
        let g = geometry
        let p = placement.normalized(in: keymap.grid)
        let r = gridRect
        return NSRect(x: r.minX + CGFloat(p.col) * g.cellWidth,
                      y: r.maxY - CGFloat(p.row + p.rowSpan) * g.cellHeight,
                      width: CGFloat(p.colSpan) * g.cellWidth,
                      height: CGFloat(p.rowSpan) * g.cellHeight)
    }

    // MARK: Mouse — ordinary AppKit events, no event tap involved

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    private func cell(at point: NSPoint) -> GridCell { geometry.cell(at: point) }

    override func mouseMoved(with event: NSEvent) {
        guard dragEnabled, dragSelection == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        hoverCell = gridRect.contains(p) ? cell(at: p) : nil
    }

    override func mouseExited(with event: NSEvent) { hoverCell = nil }

    override func mouseDown(with event: NSEvent) {
        guard dragEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard gridRect.contains(p) else { return }
        let c = cell(at: p)
        dragAnchor = c
        hoverCell = nil
        dragSelection = GridPlacement(anchor: c, focus: c)
        onDragChanged?(dragSelection)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let next = GridPlacement(anchor: anchor, focus: cell(at: p))
        guard next != dragSelection else { return }
        dragSelection = next
        onDragChanged?(dragSelection)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragAnchor != nil, let selection = dragSelection else { return }
        dragAnchor = nil
        onDragCommitted?(selection)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawChrome()
        drawHeader()
        drawGrid()
        if placementsRevealed { drawSavedPlacements() }
        drawFlashedLayout()
        drawHover()
        drawSelection()
        drawFooter()
    }

    private func drawChrome() {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.13, alpha: 0.97).setFill()
        bg.fill()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()
    }

    private func drawHeader() {
        let name = targetName ?? NSLocalizedString("Place window", tableName: "Main", value: "Place window", comment: "")
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var x = gridInsets.left
        let cy = bounds.maxY - gridInsets.top / 2 - 2
        if let icon = targetIcon {
            let box = NSRect(x: x, y: cy - 9, width: 18, height: 18)
            icon.draw(in: box)
            x += 24
        }
        let size = (name as NSString).size(withAttributes: attrs)
        (name as NSString).draw(at: NSPoint(x: x, y: cy - size.height / 2), withAttributes: attrs)
    }

    /// Cells drawn as discrete tiles rather than hairlines. The full-screen
    /// version stroked 10%-white lines over a dimmed desktop and was invisible
    /// against a busy wallpaper; on an opaque panel a tile reads at any size.
    private func drawGrid() {
        let g = geometry
        let r = gridRect
        for row in 0..<keymap.grid.rows {
            for col in 0..<keymap.grid.cols {
                let cell = NSRect(x: r.minX + CGFloat(col) * g.cellWidth,
                                  y: r.maxY - CGFloat(row + 1) * g.cellHeight,
                                  width: g.cellWidth, height: g.cellHeight).insetBy(dx: 1, dy: 1)
                NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private func drawHover() {
        guard dragEnabled, dragSelection == nil, let c = hoverCell else { return }
        let g = geometry, r = gridRect
        let cell = NSRect(x: r.minX + CGFloat(c.col) * g.cellWidth,
                          y: r.maxY - CGFloat(c.row + 1) * g.cellHeight,
                          width: g.cellWidth, height: g.cellHeight).insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
    }

    private func drawSavedPlacements() {
        let accent = NSColor.controlAccentColor
        for binding in keymap.assignedBindings {
            let r = rect(for: binding.placement).insetBy(dx: 1, dy: 1)
            guard r.width > 6, r.height > 6 else { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
            let cap = PlacementKeyLabel.text(keyCode: binding.keyCode, modifierFlags: binding.modifierFlags)
            guard !cap.isEmpty else { continue }
            let f = NSFont.systemFont(ofSize: min(11, max(8, r.height * 0.4)), weight: .semibold)
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(0.65)]
            let s = (cap as NSString).size(withAttributes: a)
            (cap as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: a)
        }
    }

    private func drawFlashedLayout() {
        guard flashedLayout != nil, let outcome = flashedOutcome else { return }
        for placement in outcome.placed {
            let r = rect(for: placement).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            path.fill()
        }
    }

    private func drawSelection() {
        let placement = dragSelection ?? flashedPlacement
        guard let placement else { return }
        let r = rect(for: placement).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawFooter() {
        let text: String
        if let warning {
            let f = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.systemOrange]
            let sz = (warning as NSString).size(withAttributes: a)
            (warning as NSString).draw(at: NSPoint(x: max(4, bounds.midX - sz.width / 2),
                                                   y: gridInsets.bottom / 2 - sz.height / 2 + 2),
                                       withAttributes: a)
            return
        }
        if let placement = dragSelection {
            text = placement.regionDescription(in: keymap.grid)
        } else if dragEnabled {
            text = NSLocalizedString("drag to place · press a key · esc",
                                     tableName: "Main", value: "drag to place · press a key · esc", comment: "")
        } else {
            text = NSLocalizedString("press a key · esc", tableName: "Main", value: "press a key · esc", comment: "")
        }
        let f = NSFont.systemFont(ofSize: 11, weight: .medium)
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        let s = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: gridInsets.bottom / 2 - s.height / 2 + 2),
                                withAttributes: a)
    }
}
