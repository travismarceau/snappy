/// PlacementOverlay.swift
///
/// The click-through pane shown while placement mode is active. It starts as a
/// small HUD hint; the full key→region map only fades in if the user hesitates
/// (or immediately / never, per `Defaults.placementMapReveal`). Pressing a bound
/// key flashes that region on the way out.

import Cocoa
import MASShortcut

// MARK: - Panel

final class PlacementOverlayPanel: NSPanel {

    private let overlayView: PlacementOverlayContentView

    init(screen: NSScreen, keymap: PlacementKeymap, leaderShortcut: MASShortcut?) {
        overlayView = PlacementOverlayContentView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size),
                                                  keymap: keymap,
                                                  leaderShortcut: leaderShortcut)
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
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .stationary]

        setFrame(screen.visibleFrame, display: false)
        contentView = overlayView
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func revealMap(animated: Bool) {
        overlayView.revealMap(animated: animated)
    }

    /// Emphasise the region that was just placed, then leave it to the caller to
    /// tear the panel down.
    func flash(_ binding: PlacementBinding) {
        overlayView.flash(binding)
    }
}

// MARK: - Content view

private final class PlacementOverlayContentView: NSView {

    private let dimView = NSView()
    private let mapView: PlacementGridView
    private let hud: PlacementHUDView

    init(frame frameRect: NSRect, keymap: PlacementKeymap, leaderShortcut: MASShortcut?) {
        mapView = PlacementGridView(frame: frameRect, keymap: keymap)
        hud = PlacementHUDView(leaderShortcut: leaderShortcut)
        super.init(frame: frameRect)

        wantsLayer = true

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        dimView.autoresizingMask = [.width, .height]
        dimView.frame = bounds
        addSubview(dimView)

        mapView.autoresizingMask = [.width, .height]
        mapView.frame = bounds
        mapView.alphaValue = 0
        addSubview(mapView)

        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    func revealMap(animated: Bool) {
        guard mapView.alphaValue < 1 else { return }
        let apply = {
            self.mapView.alphaValue = 1
            self.dimView.alphaValue = 0.16
            self.hud.alphaValue = 0
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.mapView.animator().alphaValue = 1
                self.dimView.animator().alphaValue = 0.16
                self.hud.animator().alphaValue = 0
            }
        } else {
            apply()
        }
    }

    func flash(_ binding: PlacementBinding) {
        mapView.flash(binding)
        if mapView.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                mapView.animator().alphaValue = 1
                hud.animator().alphaValue = 0
            }
        }
    }
}

// MARK: - HUD hint

private final class PlacementHUDView: NSView {

    init(leaderShortcut: MASShortcut?) {
        super.init(frame: .zero)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11, *) {
            icon.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        }
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: NSLocalizedString("Press a key to place", tableName: "Main", value: "Press a key to place", comment: ""))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let subtitle: String
        if let leaderShortcut {
            let combo = [leaderShortcut.modifierFlagsString, leaderShortcut.keyCodeString].compactMap { $0 }.joined()
            subtitle = String(format: NSLocalizedString("%@ · esc to cancel", tableName: "Main", value: "%@ · esc to cancel", comment: ""), combo)
        } else {
            subtitle = NSLocalizedString("esc to cancel", tableName: "Main", value: "esc to cancel", comment: "")
        }
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, sub])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
        ])

        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Map

final class PlacementGridView: NSView {

    private let keymap: PlacementKeymap
    private var flashedBindingID: UUID?

    init(frame frameRect: NSRect, keymap: PlacementKeymap) {
        self.keymap = keymap
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false } // matches GridPlacement.resolve (Cocoa bottom-left)

    func flash(_ binding: PlacementBinding) {
        flashedBindingID = binding.id
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.flashedBindingID = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let accent = NSColor.controlAccentColor

        drawGridLines(in: bounds)

        for binding in keymap.assignedBindings {
            let rect = binding.placement
                .resolve(in: bounds,
                         grid: keymap.grid,
                         outerMargin: keymap.outerMargin,
                         innerGap: keymap.innerGap)
                .insetBy(dx: 3, dy: 3)
            guard rect.width > 8, rect.height > 8 else { continue }

            let flashed = binding.id == flashedBindingID
            let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            accent.withAlphaComponent(flashed ? 0.50 : 0.16).setFill()
            path.fill()
            accent.withAlphaComponent(flashed ? 1.0 : 0.55).setStroke()
            path.lineWidth = flashed ? 3 : 1.5
            path.stroke()

            drawCap(for: binding, in: rect, emphasised: flashed)
        }
    }

    private func drawGridLines(in bounds: NSRect) {
        guard keymap.grid.cols > 0, keymap.grid.rows > 0 else { return }
        let usable = bounds.insetBy(dx: max(0, keymap.outerMargin), dy: max(0, keymap.outerMargin))
        NSColor.white.withAlphaComponent(0.06).setStroke()
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

    private func drawCap(for binding: PlacementBinding, in rect: NSRect, emphasised: Bool) {
        let shortcut = MASShortcut(keyCode: binding.keyCode,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: binding.modifierFlags))
        let capText = [shortcut.modifierFlagsString, shortcut.keyCodeString]
            .compactMap { $0 }
            .joined()
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
