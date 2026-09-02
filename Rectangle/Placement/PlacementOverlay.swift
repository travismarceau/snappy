/// PlacementOverlay.swift
///
/// The translucent, click-through pane shown while placement mode is active. It
/// covers one screen's visible frame and draws every assigned placement as a
/// labelled region so the keyboard geography reads as screen geography.

import Cocoa
import MASShortcut

// MARK: - Panel

final class PlacementOverlayPanel: NSPanel {

    private let gridView: PlacementGridView

    init(screen: NSScreen, keymap: PlacementKeymap) {
        gridView = PlacementGridView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size),
                                     keymap: keymap)
        super.init(contentRect: screen.visibleFrame,
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
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .stationary]

        setFrame(screen.visibleFrame, display: false)
        contentView = gridView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Briefly emphasise the region that was just placed (sticky mode feedback).
    func flash(_ binding: PlacementBinding) {
        gridView.flash(binding)
    }
}

// MARK: - Grid view

final class PlacementGridView: NSView {

    private let keymap: PlacementKeymap
    private var flashedBindingID: UUID?

    init(frame frameRect: NSRect, keymap: PlacementKeymap) {
        self.keymap = keymap
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false } // match Cocoa bottom-left, like GridPlacement.resolve

    func flash(_ binding: PlacementBinding) {
        flashedBindingID = binding.id
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.flashedBindingID = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()

        drawBaseGrid(in: bounds)

        let accent = NSColor.controlAccentColor
        for binding in keymap.assignedBindings {
            let rect = binding.placement
                .resolve(in: bounds,
                         grid: keymap.grid,
                         outerMargin: keymap.outerMargin,
                         innerGap: keymap.innerGap)
                .insetBy(dx: 1, dy: 1)
            guard rect.width > 4, rect.height > 4 else { continue }

            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            let isFlashed = binding.id == flashedBindingID
            accent.withAlphaComponent(isFlashed ? 0.55 : 0.22).setFill()
            path.fill()
            accent.withAlphaComponent(0.9).setStroke()
            path.lineWidth = isFlashed ? 4 : 2
            path.stroke()

            drawCap(for: binding, in: rect)
        }
    }

    private func drawBaseGrid(in bounds: NSRect) {
        guard keymap.grid.cols > 0, keymap.grid.rows > 0 else { return }
        let margin = max(0, keymap.outerMargin)
        let usable = bounds.insetBy(dx: margin, dy: margin)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1

        for c in 0...keymap.grid.cols {
            let x = usable.minX + usable.width * CGFloat(c) / CGFloat(keymap.grid.cols)
            line.move(to: NSPoint(x: x, y: usable.minY))
            line.line(to: NSPoint(x: x, y: usable.maxY))
        }
        for r in 0...keymap.grid.rows {
            let y = usable.minY + usable.height * CGFloat(r) / CGFloat(keymap.grid.rows)
            line.move(to: NSPoint(x: usable.minX, y: y))
            line.line(to: NSPoint(x: usable.maxX, y: y))
        }
        line.stroke()
    }

    private func drawCap(for binding: PlacementBinding, in rect: NSRect) {
        let shortcut = MASShortcut(keyCode: binding.keyCode,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: binding.modifierFlags))
        let cap = [shortcut.modifierFlagsString, shortcut.keyCodeString]
            .compactMap { $0 }
            .joined()
        let capText = cap.isEmpty ? binding.label : cap

        let capSize = min(rect.width, rect.height) * 0.42
        let capFont = NSFont.systemFont(ofSize: max(14, min(capSize, 72)), weight: .semibold)
        draw(text: capText,
             font: capFont,
             color: NSColor.white.withAlphaComponent(0.95),
             centeredIn: rect,
             offsetY: binding.label.isEmpty ? 0 : rect.height * 0.10)

        if !binding.label.isEmpty {
            draw(text: binding.label,
                 font: NSFont.systemFont(ofSize: max(10, min(rect.height * 0.12, 18))),
                 color: NSColor.white.withAlphaComponent(0.7),
                 centeredIn: rect,
                 offsetY: -rect.height * 0.22)
        }
    }

    private func draw(text: String, font: NSFont, color: NSColor, centeredIn rect: NSRect, offsetY: CGFloat) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2 + offsetY)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
