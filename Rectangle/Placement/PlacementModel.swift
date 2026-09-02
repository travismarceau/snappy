/// PlacementModel.swift
///
/// Divvy-style window placement: the screen is divided into an N×M grid and each
/// user-defined placement is a rectangular block of cells bound to a single key.
/// These types are pure value types with no AppKit dependency beyond CoreGraphics
/// so the geometry can be unit tested in isolation.

import CoreGraphics
import Foundation

// MARK: - Modifier mask

/// The four device-independent modifier bits (⌃⌥⇧⌘) as used by
/// `NSEvent.ModifierFlags.rawValue`, without importing AppKit into the model.
let placementModifierMask: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

// MARK: - Grid

struct PlacementGrid: Codable, Equatable {
    var rows: Int
    var cols: Int

    static let maxDimension = 16
    static let `default` = PlacementGrid(rows: 6, cols: 6)

    init(rows: Int = 6, cols: Int = 6) {
        self.rows = max(1, min(rows, PlacementGrid.maxDimension))
        self.cols = max(1, min(cols, PlacementGrid.maxDimension))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 6
        let cc = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 6
        self.init(rows: r, cols: cc)
    }
}

// MARK: - Display target

/// Which display a placement acts on. `.current` (the common case) means "the
/// display the active window / cursor is already on", matching Rectangle's
/// existing screen detection. `.next` cycles to the adjacent display. `.index`
/// pins a specific display by its index in `NSScreen.screens`.
enum PlacementDisplayTarget: Equatable {
    case current
    case next
    case index(Int)

    /// Wire format: nil = current, -1 = next, >= 0 = specific index.
    var rawIndex: Int? {
        switch self {
        case .current: return nil
        case .next: return -1
        case .index(let i): return i
        }
    }

    init(rawIndex: Int?) {
        switch rawIndex {
        case .none: self = .current
        case .some(-1): self = .next
        case .some(let i) where i >= 0: self = .index(i)
        default: self = .current
        }
    }
}

// MARK: - Placement

/// A rectangular block of grid cells. `row`/`col` are 0-based; `row` counts from
/// the TOP of the screen (natural for the editor). `resolve` converts to a
/// Cocoa (bottom-left origin) rect suitable for a `WindowCalculationResult`.
struct GridPlacement: Codable, Equatable {
    var col: Int
    var row: Int
    var colSpan: Int
    var rowSpan: Int
    /// Stored on the wire as an optional Int (see `PlacementDisplayTarget.rawIndex`).
    var displayIndexRaw: Int?

    enum CodingKeys: String, CodingKey {
        case col, row, colSpan, rowSpan
        case displayIndexRaw = "display"
    }

    init(col: Int, row: Int, colSpan: Int, rowSpan: Int, display: PlacementDisplayTarget = .current) {
        self.col = col
        self.row = row
        self.colSpan = max(1, colSpan)
        self.rowSpan = max(1, rowSpan)
        self.displayIndexRaw = display.rawIndex
    }

    var display: PlacementDisplayTarget {
        get { PlacementDisplayTarget(rawIndex: displayIndexRaw) }
        set { displayIndexRaw = newValue.rawIndex }
    }

    /// Clamp the block so it lies fully inside `grid`.
    func normalized(in grid: PlacementGrid) -> GridPlacement {
        var p = self
        p.colSpan = max(1, min(colSpan, grid.cols))
        p.rowSpan = max(1, min(rowSpan, grid.rows))
        p.col = max(0, min(col, grid.cols - p.colSpan))
        p.row = max(0, min(row, grid.rows - p.rowSpan))
        return p
    }

    /// Resolve to a Cocoa (bottom-left origin) rect inside `visibleFrame`
    /// (typically `NSScreen.adjustedVisibleFrame`). `outerMargin` is the gap
    /// between the screen edge and any window; `innerGap` is the gap between two
    /// adjacent windows. Result is pixel-rounded.
    func resolve(in visibleFrame: CGRect,
                 grid: PlacementGrid,
                 outerMargin: CGFloat,
                 innerGap: CGFloat) -> CGRect {
        let p = normalized(in: grid)
        let cols = CGFloat(grid.cols)
        let rows = CGFloat(grid.rows)

        let margin = max(0, outerMargin)
        let gap = max(0, innerGap)

        let usableWidth = max(1, visibleFrame.width - 2 * margin)
        let usableHeight = max(1, visibleFrame.height - 2 * margin)

        // Width / height of a single column / row track once inner gaps removed.
        let trackW = max(1, (usableWidth - (cols - 1) * gap) / cols)
        let trackH = max(1, (usableHeight - (rows - 1) * gap) / rows)

        let spanW = CGFloat(p.colSpan) * trackW + CGFloat(p.colSpan - 1) * gap
        let spanH = CGFloat(p.rowSpan) * trackH + CGFloat(p.rowSpan - 1) * gap

        let xFromLeft = CGFloat(p.col) * (trackW + gap)
        // `row` counts from the top; flip into Cocoa's bottom-left space.
        let yFromTop = CGFloat(p.row) * (trackH + gap)
        let yFromBottom = usableHeight - yFromTop - spanH

        return CGRect(
            x: (visibleFrame.minX + margin + xFromLeft).rounded(),
            y: (visibleFrame.minY + margin + yFromBottom).rounded(),
            width: spanW.rounded(),
            height: spanH.rounded()
        )
    }

    /// e.g. "cols 1–3 / rows 1–6" (1-based, inclusive) for the editor table.
    func regionDescription(in grid: PlacementGrid) -> String {
        let p = normalized(in: grid)
        let c1 = p.col + 1, c2 = p.col + p.colSpan
        let r1 = p.row + 1, r2 = p.row + p.rowSpan
        let cPart = c1 == c2 ? "col \(c1)" : "cols \(c1)–\(c2)"
        let rPart = r1 == r2 ? "row \(r1)" : "rows \(r1)–\(r2)"
        return "\(cPart) / \(rPart)"
    }
}

// MARK: - Key binding

struct PlacementBinding: Codable, Equatable, Identifiable {
    var id: UUID
    /// Carbon `kVK_*` key code. `unassignedKeyCode` means no key chosen yet.
    var keyCode: Int
    /// Usually 0 (a bare key). `NSEvent.ModifierFlags.rawValue` masked to the
    /// device-independent set (`placementModifierMask`).
    var modifierFlags: UInt
    var label: String
    var placement: GridPlacement

    static let unassignedKeyCode = -1

    init(id: UUID = UUID(),
         keyCode: Int = PlacementBinding.unassignedKeyCode,
         modifierFlags: UInt = 0,
         label: String = "",
         placement: GridPlacement) {
        self.id = id
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags & placementModifierMask
        self.label = label
        self.placement = placement
    }

    enum CodingKeys: String, CodingKey {
        case id, keyCode, modifierFlags, label, placement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode) ?? PlacementBinding.unassignedKeyCode
        modifierFlags = (try c.decodeIfPresent(UInt.self, forKey: .modifierFlags) ?? 0) & placementModifierMask
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        placement = try c.decode(GridPlacement.self, forKey: .placement)
    }

    var isAssigned: Bool { keyCode >= 0 }
}

// MARK: - Keymap

struct PlacementKeymap: Codable, Equatable {
    var grid: PlacementGrid
    var outerMargin: CGFloat
    var innerGap: CGFloat
    var bindings: [PlacementBinding]

    static let empty = PlacementKeymap()

    init(grid: PlacementGrid = .default,
         outerMargin: CGFloat = 0,
         innerGap: CGFloat = 0,
         bindings: [PlacementBinding] = []) {
        self.grid = grid
        self.outerMargin = max(0, outerMargin)
        self.innerGap = max(0, innerGap)
        self.bindings = bindings
    }

    enum CodingKeys: String, CodingKey {
        case grid, outerMargin, innerGap, bindings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let grid = try c.decodeIfPresent(PlacementGrid.self, forKey: .grid) ?? .default
        let outer = try c.decodeIfPresent(CGFloat.self, forKey: .outerMargin) ?? 0
        let inner = try c.decodeIfPresent(CGFloat.self, forKey: .innerGap) ?? 0
        let bindings = try c.decodeIfPresent([PlacementBinding].self, forKey: .bindings) ?? []
        self.init(grid: grid, outerMargin: outer, innerGap: inner, bindings: bindings)
    }

    var assignedBindings: [PlacementBinding] { bindings.filter { $0.isAssigned } }

    /// First assigned binding matching the pressed key, or nil.
    func binding(forKeyCode keyCode: Int, modifierFlags: UInt) -> PlacementBinding? {
        let mods = modifierFlags & placementModifierMask
        return bindings.first {
            $0.isAssigned
                && $0.keyCode == keyCode
                && ($0.modifierFlags & placementModifierMask) == mods
        }
    }

    /// True if `keyCode`+`mods` is already taken by a *different* binding.
    func hasConflict(keyCode: Int, modifierFlags: UInt, excluding id: UUID) -> Bool {
        guard keyCode >= 0 else { return false }
        let mods = modifierFlags & placementModifierMask
        return bindings.contains {
            $0.id != id
                && $0.isAssigned
                && $0.keyCode == keyCode
                && ($0.modifierFlags & placementModifierMask) == mods
        }
    }
}
