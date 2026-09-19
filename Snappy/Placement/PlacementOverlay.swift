/// PlacementOverlay.swift
///
/// The click-through pane shown while placement mode is active.
///
/// The grid and the hint line are drawn the moment the pane appears — you
/// cannot aim at a grid you cannot see, and a drag needs one immediately. The
/// saved key→region map is a separate layer on top, revealed per
/// `Defaults.placementMapReveal`, and drawn as outlines rather than filled
/// blocks: overlapping placements used to stack their alpha into unreadable
/// blobs. Only one thing on screen is ever filled — the live drag rect, or the
/// region a keystroke just placed. Filled means happening now.

import Cocoa
import MASShortcut

// MARK: - Key labels

/// The "⌃⌥A" text for a key binding. Shared by the overlay's keycaps and its
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

    private let overlayView: PlacementOverlayContentView

    /// What this panel was built for, so `PlacementModeController` can tell
    /// whether a cached panel is still good for the next session — and, once
    /// there is one panel per display, which screen a mouse event belongs to.
    /// The display this pane covers. Named around the target rather than
    /// shadowing `NSWindow.screen`, which reports where the window happens to be.
    let targetScreen: NSScreen
    let screenFrame: CGRect
    let keymap: PlacementKeymap

    init(screen: NSScreen, frame: CGRect, keymap: PlacementKeymap, dragEnabled: Bool) {
        self.targetScreen = screen
        self.screenFrame = frame
        self.keymap = keymap
        overlayView = PlacementOverlayContentView(frame: NSRect(origin: .zero, size: frame.size),
                                                  keymap: keymap,
                                                  dragEnabled: dragEnabled)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .stationary]

        setFrame(frame, display: false)
        contentView = overlayView
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// True when a cached panel can be reused as-is for a new session.
    func matches(frame: CGRect, keymap: PlacementKeymap, dragEnabled: Bool) -> Bool {
        screenFrame == frame && self.keymap == keymap && overlayView.dragEnabled == dragEnabled
    }

    /// Wipe per-session state so a cached panel opens looking new.
    func prepareForReuse() {
        overlayView.prepareForReuse()
        alphaValue = 0
    }

    func present() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            animator().alphaValue = 1
        }
    }

    /// Fade out on the way to teardown, so the window is seen landing under the
    /// dissolving grid rather than the grid cutting to an unchanged screen.
    func dismiss(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Outline the saved placements over the grid.
    func revealPlacements(animated: Bool) {
        overlayView.revealPlacements(animated: animated)
    }

    // MARK: Drag

    func updateHover(_ cell: GridCell?) {
        overlayView.updateHover(cell)
    }

    func updateDrag(_ placement: GridPlacement?) {
        overlayView.updateDrag(placement)
    }

    func clearDrag() {
        overlayView.updateDrag(nil)
    }

    // MARK: Flash

    /// Emphasise the region that was just placed, then leave it to the caller to
    /// tear the panel down.
    func flash(placement: GridPlacement) {
        overlayView.flash(placement: placement)
    }

    /// The same confirmation for a layout: its chip lights up and every region
    /// it actually filled is drawn, so you can see where the windows went. Any
    /// app it couldn't place is named underneath.
    func flash(layout: WindowLayout, outcome: PlacementModeController.LayoutOutcome) {
        overlayView.flash(layout: layout, outcome: outcome)
    }
}

// MARK: - Content view

private final class PlacementOverlayContentView: NSView {

    private let dimView = NSView()
    private let gridView: PlacementGridView
    private let presetView: PlacementPresetView
    let dragEnabled: Bool

    init(frame frameRect: NSRect, keymap: PlacementKeymap, dragEnabled: Bool) {
        self.dragEnabled = dragEnabled
        gridView = PlacementGridView(frame: frameRect, keymap: keymap, dragEnabled: dragEnabled)
        presetView = PlacementPresetView(frame: frameRect, keymap: keymap)
        super.init(frame: frameRect)

        wantsLayer = true

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0.16
        dimView.autoresizingMask = [.width, .height]
        dimView.frame = bounds
        addSubview(dimView)

        for view in [gridView, presetView] as [NSView] {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            addSubview(view)
        }
        presetView.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func prepareForReuse() {
        super.prepareForReuse()
        presetView.alphaValue = 0
        presetView.reset()
        gridView.reset()
    }

    func revealPlacements(animated: Bool) {
        guard presetView.alphaValue < 1 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                presetView.animator().alphaValue = 1
            }
        } else {
            presetView.alphaValue = 1
        }
    }

    func updateHover(_ cell: GridCell?) {
        gridView.hoverCell = cell
    }

    func updateDrag(_ placement: GridPlacement?) {
        gridView.dragSelection = placement
        // The drag rect owns the screen while it is live; the saved map recedes
        // to a whisper rather than competing with it.
        let target: CGFloat = placement == nil ? 1 : 0.35
        if presetView.alphaValue > 0, presetView.alphaValue != target {
            presetView.alphaValue = target
        }
    }

    func flash(placement: GridPlacement) {
        presetView.flash(placement: placement)
        revealPlacements(animated: presetView.alphaValue == 0)
        presetView.alphaValue = 1
    }

    func flash(layout: WindowLayout, outcome: PlacementModeController.LayoutOutcome) {
        presetView.flash(layout: layout, outcome: outcome)
        revealPlacements(animated: presetView.alphaValue == 0)
        presetView.alphaValue = 1
    }
}

// MARK: - Grid, hover, drag

/// The always-visible layer: grid lines, the cell under the cursor, the live
/// drag rect and the hint line.
final class PlacementGridView: NSView {

    private let keymap: PlacementKeymap
    private let dragEnabled: Bool

    var hoverCell: GridCell? {
        didSet { if hoverCell != oldValue { needsDisplay = true } }
    }
    var dragSelection: GridPlacement? {
        didSet { if dragSelection != oldValue { needsDisplay = true } }
    }

    init(frame frameRect: NSRect, keymap: PlacementKeymap, dragEnabled: Bool) {
        self.keymap = keymap
        self.dragEnabled = dragEnabled
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false } // matches GridPlacement.resolve (Cocoa bottom-left)

    func reset() {
        hoverCell = nil
        dragSelection = nil
        needsDisplay = true
    }

    private var geometry: PlacementGridGeometry {
        PlacementGridGeometry(bounds: bounds, grid: keymap.grid, outerMargin: keymap.outerMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGridLines()
        drawHover()
        drawDragSelection()
        drawHint()
    }

    private func drawGridLines() {
        guard keymap.grid.cols > 0, keymap.grid.rows > 0 else { return }
        let g = geometry
        let usable = g.usableRect
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        for c in 0...keymap.grid.cols {
            let x = usable.minX + g.cellWidth * CGFloat(c)
            line.move(to: NSPoint(x: x, y: usable.minY))
            line.line(to: NSPoint(x: x, y: usable.maxY))
        }
        for r in 0...keymap.grid.rows {
            let y = usable.minY + g.cellHeight * CGFloat(r)
            line.move(to: NSPoint(x: usable.minX, y: y))
            line.line(to: NSPoint(x: usable.maxX, y: y))
        }
        line.stroke()
    }

    private func drawHover() {
        guard dragEnabled, dragSelection == nil, let cell = hoverCell else { return }
        let g = geometry
        let usable = g.usableRect
        let rect = NSRect(x: usable.minX + CGFloat(cell.col) * g.cellWidth,
                          y: usable.maxY - CGFloat(cell.row + 1) * g.cellHeight,
                          width: g.cellWidth,
                          height: g.cellHeight)
        NSColor.white.withAlphaComponent(0.10).setFill()
        rect.insetBy(dx: 1, dy: 1).fill()
    }

    private func drawDragSelection() {
        guard let placement = dragSelection else { return }
        let rect = placement.resolve(in: bounds,
                                     grid: keymap.grid,
                                     outerMargin: keymap.outerMargin,
                                     innerGap: keymap.innerGap)
        let drawn = rect.insetBy(dx: 3, dy: 3)
        guard drawn.width > 8, drawn.height > 8 else { return }

        let accent = NSColor.controlAccentColor
        let path = NSBezierPath(roundedRect: drawn, xRadius: 14, yRadius: 14)
        accent.withAlphaComponent(0.38).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 3
        path.stroke()

        drawSizeChip(for: placement, rect: rect)
    }

    /// The pane is framed to the same rect placements resolve against, so the
    /// drag rect's size in points is literally the window's size to come.
    private func drawSizeChip(for placement: GridPlacement, rect: NSRect) {
        let size = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let sizeFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: sizeFont,
            .foregroundColor: NSColor.white,
        ]
        let sizeSize = (size as NSString).size(withAttributes: sizeAttrs)
        guard rect.width > sizeSize.width + 24, rect.height > 44 else { return }

        let detail = placement.regionDescription(in: keymap.grid)
        let detailFont = NSFont.systemFont(ofSize: 12)
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        let detailSize = (detail as NSString).size(withAttributes: detailAttrs)
        let showDetail = rect.height > 74 && rect.width > detailSize.width + 24

        let contentH = sizeSize.height + (showDetail ? detailSize.height + 3 : 0)
        let contentW = max(sizeSize.width, showDetail ? detailSize.width : 0)
        let padX: CGFloat = 12, padY: CGFloat = 7
        let chip = NSRect(x: rect.midX - contentW / 2 - padX,
                          y: rect.midY - contentH / 2 - padY,
                          width: contentW + padX * 2,
                          height: contentH + padY * 2)
        NSColor.black.withAlphaComponent(0.40).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()

        let sizeY = showDetail ? chip.maxY - padY - sizeSize.height : chip.midY - sizeSize.height / 2
        (size as NSString).draw(at: NSPoint(x: chip.midX - sizeSize.width / 2, y: sizeY),
                                withAttributes: sizeAttrs)
        if showDetail {
            (detail as NSString).draw(at: NSPoint(x: chip.midX - detailSize.width / 2, y: chip.minY + padY),
                                      withAttributes: detailAttrs)
        }
    }

    /// Replaces the old blurred HUD panel. A line of text costs nothing to
    /// draw; an NSVisualEffectView was the most expensive thing in the overlay
    /// and it only ever said what this says.
    private func drawHint() {
        guard dragSelection == nil else { return }
        let text = dragEnabled
            ? NSLocalizedString("drag to place · press a key · esc to cancel", tableName: "Main",
                                value: "drag to place · press a key · esc to cancel", comment: "")
            : NSLocalizedString("press a key · esc to cancel", tableName: "Main",
                                value: "press a key · esc to cancel", comment: "")
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 12
        let chip = NSRect(x: bounds.midX - (size.width + pad * 2) / 2,
                          y: bounds.minY + 14,
                          width: size.width + pad * 2,
                          height: size.height + 10)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: chip.midX - size.width / 2, y: chip.minY + 5),
                                withAttributes: attrs)
    }
}

// MARK: - Saved placements

/// The revealable layer: the saved key→region map, outlined, plus whatever a
/// keystroke just placed.
final class PlacementPresetView: NSView {

    private let keymap: PlacementKeymap
    private var flashedPlacement: GridPlacement?
    private var flashedLayout: WindowLayout?
    private var flashedOutcome: PlacementModeController.LayoutOutcome?

    init(frame frameRect: NSRect, keymap: PlacementKeymap) {
        self.keymap = keymap
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    func reset() {
        flashedPlacement = nil
        flashedLayout = nil
        flashedOutcome = nil
        needsDisplay = true
    }

    func flash(placement: GridPlacement) {
        flashedPlacement = placement
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.flashedPlacement = nil
            self?.needsDisplay = true
        }
    }

    func flash(layout: WindowLayout, outcome: PlacementModeController.LayoutOutcome) {
        flashedLayout = layout
        flashedOutcome = outcome
        needsDisplay = true
        // Held longer than a placement flash: there is a sentence to read when
        // an app was missing, and several regions to take in either way.
        let hold = outcome.isComplete ? 0.35 : 1.4
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.flashedLayout = nil
            self?.flashedOutcome = nil
            self?.needsDisplay = true
        }
    }

    private func rect(for placement: GridPlacement) -> NSRect {
        placement.resolve(in: bounds,
                          grid: keymap.grid,
                          outerMargin: keymap.outerMargin,
                          innerGap: keymap.innerGap)
            .insetBy(dx: 3, dy: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        for binding in keymap.assignedBindings {
            let r = rect(for: binding.placement)
            guard r.width > 8, r.height > 8 else { continue }

            let flashed = binding.placement == flashedPlacement
            let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
            // Outlines only unless this is the region a keystroke just placed:
            // a fill means "happening now", and stacking translucent fills over
            // overlapping placements is what made this unreadable.
            if flashed {
                accent.withAlphaComponent(0.50).setFill()
                path.fill()
            }
            accent.withAlphaComponent(flashed ? 1.0 : 0.45).setStroke()
            path.lineWidth = flashed ? 3 : 1
            path.stroke()

            drawCap(for: binding, in: r, emphasised: flashed)
        }

        drawFlashedLayout()
        drawLayoutLegend()
        drawMissingAppsNote()
    }

    /// The regions a layout actually filled, drawn with the same emphasis a
    /// flashed placement gets - the answer to "where did my windows go". Slots
    /// that couldn't be placed are deliberately not drawn; showing them would
    /// claim a window is somewhere it isn't.
    private func drawFlashedLayout() {
        guard flashedLayout != nil, let outcome = flashedOutcome else { return }
        let accent = NSColor.controlAccentColor

        for placement in outcome.placed {
            let r = rect(for: placement)
            guard r.width > 8, r.height > 8 else { continue }

            let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
            accent.withAlphaComponent(0.50).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }

    /// A layout that placed only some of its windows looks broken unless it says
    /// which app wasn't there - and "not running" and "running with no window"
    /// call for different things from the reader, so they are named separately.
    private func drawMissingAppsNote() {
        guard let outcome = flashedOutcome, !outcome.isComplete else { return }

        var parts: [String] = []
        if !outcome.notRunning.isEmpty {
            let names = outcome.notRunning.joined(separator: ", ")
            parts.append(outcome.notRunning.count == 1
                ? String(format: NSLocalizedString("%@ isn’t running", tableName: "Main", value: "%@ isn’t running", comment: ""), names)
                : String(format: NSLocalizedString("%@ aren’t running", tableName: "Main", value: "%@ aren’t running", comment: ""), names))
        }
        if !outcome.noWindow.isEmpty {
            let names = outcome.noWindow.joined(separator: ", ")
            parts.append(outcome.noWindow.count == 1
                ? String(format: NSLocalizedString("%@ has no open window", tableName: "Main", value: "%@ has no open window", comment: ""), names)
                : String(format: NSLocalizedString("%@ have no open windows", tableName: "Main", value: "%@ have no open windows", comment: ""), names))
        }
        let text = parts.joined(separator: "  ·  ")

        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let pad: CGFloat = 14
        let rect = NSRect(x: bounds.midX - (size.width + pad * 2) / 2,
                          y: bounds.minY + 106,
                          width: size.width + pad * 2,
                          height: 34)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + pad, y: rect.midY - font.pointSize / 2 - 2),
                                withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }

    /// Multi-window layouts can't be drawn as a single region, so list them as
    /// key chips along the bottom.
    private func drawLayoutLegend() {
        let layouts = keymap.assignedLayouts
        guard !layouts.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        var chips: [(key: String, label: String, keyW: CGFloat, labelW: CGFloat)] = []
        for layout in layouts {
            let key = PlacementKeyLabel.text(keyCode: layout.keyCode, modifierFlags: layout.modifierFlags)
            let label = layout.label.isEmpty ? "\(layout.slots.count) windows" : layout.label
            let kw = (key as NSString).size(withAttributes: [.font: keyFont]).width
            let lw = (label as NSString).size(withAttributes: [.font: font]).width
            chips.append((key, label, kw, lw))
        }

        let pad: CGFloat = 12, gap: CGFloat = 10, chipGap: CGFloat = 18
        let widths = chips.map { $0.keyW + gap + $0.labelW + pad * 2 }
        let totalW = widths.reduce(0, +) + chipGap * CGFloat(max(chips.count - 1, 0))
        var x = bounds.midX - totalW / 2
        let y = bounds.minY + 58
        let h: CGFloat = 34

        for (i, chip) in chips.enumerated() {
            let rect = NSRect(x: x, y: y, width: widths[i], height: h)
            let flashed = layouts[i].id == flashedLayout?.id
            (flashed ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                     : NSColor.black.withAlphaComponent(0.32)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            (chip.key as NSString).draw(
                at: NSPoint(x: rect.minX + pad, y: rect.midY - keyFont.pointSize / 2 - 2),
                withAttributes: [.font: keyFont, .foregroundColor: NSColor.white])
            (chip.label as NSString).draw(
                at: NSPoint(x: rect.minX + pad + chip.keyW + gap, y: rect.midY - font.pointSize / 2 - 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
            x += widths[i] + chipGap
        }
    }

    private func drawCap(for binding: PlacementBinding, in rect: NSRect, emphasised: Bool) {
        let capText = PlacementKeyLabel.text(keyCode: binding.keyCode, modifierFlags: binding.modifierFlags)
        guard !capText.isEmpty || !binding.label.isEmpty else { return }

        let capFontSize = max(13, min(min(rect.width, rect.height) * 0.28, 30))
        let capFont = NSFont.systemFont(ofSize: capFontSize, weight: .semibold)
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: capFont,
            .foregroundColor: NSColor.white.withAlphaComponent(emphasised ? 1.0 : 0.92),
        ]
        let capSize = (capText as NSString).size(withAttributes: capAttrs)

        // Keycap chip
        let padX: CGFloat = 10, padY: CGFloat = 5
        let chip = NSRect(x: rect.midX - capSize.width / 2 - padX,
                          y: rect.midY - capSize.height / 2 - padY + (binding.label.isEmpty ? 0 : rect.height * 0.06),
                          width: capSize.width + padX * 2,
                          height: capSize.height + padY * 2)
        if !capText.isEmpty {
            NSColor.black.withAlphaComponent(emphasised ? 0.45 : 0.30).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
            (capText as NSString).draw(at: NSPoint(x: chip.midX - capSize.width / 2,
                                                   y: chip.midY - capSize.height / 2),
                                       withAttributes: capAttrs)
        }

        if !binding.label.isEmpty, rect.height > 44 {
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(10, min(rect.height * 0.10, 15))),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]
            let ls = (binding.label as NSString).size(withAttributes: labelAttrs)
            (binding.label as NSString).draw(at: NSPoint(x: rect.midX - ls.width / 2,
                                                        y: chip.minY - ls.height - 4),
                                             withAttributes: labelAttrs)
        }
    }
}
