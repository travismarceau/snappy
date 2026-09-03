/// PlacementConfigUI.swift
///
/// Shared AppKit building blocks for the Placement settings tab so the
/// Placements sub-pane (`PlacementConfigViewController`) and the Layouts
/// sub-pane (`LayoutsPaneView`) render identically: the same titled cards,
/// form grids, tables, add/remove control, and empty-state labels.

import Cocoa

enum PlacementUI {
    static let outerMargin: CGFloat = 20
    static let columnGutter: CGFloat = 16
    static let cardRowGap: CGFloat = 16
    static let formRowSpacing: CGFloat = 8
    static let cardHPadding: CGFloat = 16
    static let cardVPadding: CGFloat = 14
}

// MARK: - Titled card

/// A section header above a rounded, bordered card wrapping `content` with
/// interior padding. Optional `subtitle` sits under the header; optional
/// `footnote` sits under the card. When `fillsHeight` is false the card hugs
/// its content; when true the content is pinned to fill the card.
func titledCard(_ title: String,
                _ content: NSView,
                fillsHeight: Bool = false,
                subtitle: String? = nil,
                footnote: String? = nil) -> NSView {
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
    let contentBottom = content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -PlacementUI.cardVPadding)
    contentBottom.priority = fillsHeight ? .required : .defaultHigh
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: PlacementUI.cardHPadding),
        content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -PlacementUI.cardHPadding),
        content.topAnchor.constraint(equalTo: card.topAnchor, constant: PlacementUI.cardVPadding),
        contentBottom,
        card.bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: PlacementUI.cardVPadding),
    ])

    container.addSubview(header)
    container.addSubview(card)

    var top: NSLayoutYAxisAnchor = header.bottomAnchor
    if let subtitle {
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sub)
        NSLayoutConstraint.activate([
            sub.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        top = sub.bottomAnchor
    }

    var bottom: NSLayoutYAxisAnchor = card.bottomAnchor
    if let footnote {
        let note = NSTextField(wrappingLabelWithString: footnote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(note)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        ])
        bottom = note.bottomAnchor
    }

    NSLayoutConstraint.activate([
        header.topAnchor.constraint(equalTo: container.topAnchor),
        header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
        header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        card.topAnchor.constraint(equalTo: top, constant: 6),
        card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        bottom.constraint(equalTo: container.bottomAnchor),
    ])
    return container
}

// MARK: - Form grid

func formGrid(_ rows: [[NSView]], rowSpacing: CGFloat = PlacementUI.formRowSpacing) -> NSGridView {
    for row in rows { for v in row { v.translatesAutoresizingMaskIntoConstraints = false } }
    let grid = NSGridView(views: rows)
    grid.rowSpacing = rowSpacing
    grid.columnSpacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
    if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
    for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
    return grid
}

func rightLabel(_ s: String) -> NSTextField {
    let tf = NSTextField(labelWithString: s)
    tf.alignment = .right
    tf.textColor = .labelColor
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.setContentHuggingPriority(.required, for: .horizontal)
    return tf
}

func hStack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = align
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func uiSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
}

func leadingWrap(_ v: NSView) -> NSView { hStack([v, uiSpacer()], spacing: 0) }

func fillWrap(_ v: NSView) -> NSView {
    let s = hStack([v], spacing: 0)
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return s
}

func pair(_ field: NSView, caption: String) -> NSView {
    let cap = NSTextField(labelWithString: caption)
    cap.textColor = .secondaryLabelColor
    cap.font = .systemFont(ofSize: 11)
    return hStack([field, cap, uiSpacer()], spacing: 6)
}

func captioned(_ control: NSView, _ caption: String) -> NSView {
    let cap = NSTextField(labelWithString: caption)
    cap.textColor = .secondaryLabelColor
    cap.font = .systemFont(ofSize: 11)
    cap.lineBreakMode = .byTruncatingTail
    cap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return hStack([control, cap, uiSpacer()], spacing: 8)
}

func stepperRow(_ field: NSTextField, _ stepper: NSStepper) -> NSView {
    hStack([field, stepper, uiSpacer()], spacing: 4)
}

func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .small
    b.font = .systemFont(ofSize: 11)
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
}

// MARK: - Add / remove segmented control

func makeAddRemove(target: AnyObject, action: Selector) -> NSSegmentedControl {
    let c = NSSegmentedControl()
    c.segmentStyle = .separated
    c.trackingMode = .momentary
    c.segmentCount = 2
    c.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
    c.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
    c.setWidth(30, forSegment: 0)
    c.setWidth(30, forSegment: 1)
    c.target = target
    c.action = action
    c.translatesAutoresizingMaskIntoConstraints = false
    return c
}

// MARK: - Item table

/// Style `table` the shared way, add its columns (`(identifier, title, width)`),
/// and return it inside a bordered scroll view.
func styledScroll(wrapping table: NSTableView,
                  columns: [(String, String, CGFloat)],
                  rowHeight: CGFloat = 24) -> NSScrollView {
    for (id, title, w) in columns {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        col.width = w
        table.addTableColumn(col)
    }
    table.rowHeight = rowHeight
    table.usesAlternatingRowBackgroundColors = false
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    if #available(macOS 11, *) { table.style = .inset }

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .lineBorder
    scroll.drawsBackground = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
}

/// A cell text field configured the shared way; `mono` for the Key column.
func tableCellTextField(mono: Bool) -> NSTextField {
    let tf = NSTextField(labelWithString: "")
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.lineBreakMode = .byTruncatingTail
    tf.font = mono ? .monospacedSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 13)
    return tf
}

// MARK: - Grouped sub-area

/// A rounded, faintly tinted container for grouping controls inside a card.
/// Re-resolves its colours on appearance change — a `layer.backgroundColor` set
/// once would freeze whatever the dynamic colour happened to be at build time.
final class TintedGroupView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Empty state

/// A dimmed, centred hint to overlay an empty table's scroll view. Pin it to
/// the scroll view's centre and toggle `isHidden` with the row count.
func emptyStateLabel(_ text: String) -> NSTextField {
    let tf = NSTextField(wrappingLabelWithString: text)
    tf.alignment = .center
    tf.font = .systemFont(ofSize: 12)
    tf.textColor = .tertiaryLabelColor
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.setContentHuggingPriority(.defaultHigh, for: .vertical)
    return tf
}
