/// PlacementTests.swift

import XCTest
import Cocoa
import CoreGraphics
@testable import Snappy

final class GridPlacementGeometryTests: XCTestCase {

    private let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let grid = PlacementGrid(rows: 6, cols: 6)

    private func resolve(_ p: GridPlacement, outer: CGFloat = 0, inner: CGFloat = 0) -> CGRect {
        p.resolve(in: frame, grid: grid, outerMargin: outer, innerGap: inner)
    }

    func testFullGridFillsVisibleFrame() {
        let r = resolve(GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 6))
        XCTAssertEqual(r, frame)
    }

    func testLeftHalf() {
        let r = resolve(GridPlacement(col: 0, row: 0, colSpan: 3, rowSpan: 6))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testRightHalf() {
        let r = resolve(GridPlacement(col: 3, row: 0, colSpan: 3, rowSpan: 6))
        XCTAssertEqual(r, CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testTopHalfIsHighInCocoaSpace() {
        // row counts from the top; the top half lives at the high-Y end.
        let r = resolve(GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 3))
        XCTAssertEqual(r, CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testBottomHalfIsLowInCocoaSpace() {
        let r = resolve(GridPlacement(col: 0, row: 3, colSpan: 6, rowSpan: 3))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1600, height: 500))
    }

    func testCenterSixth() {
        let r = resolve(GridPlacement(col: 2, row: 2, colSpan: 2, rowSpan: 2))
        // trackW = 1600/6, trackH = 1000/6
        XCTAssertEqual(r.width, (1600.0 / 6 * 2).rounded())
        XCTAssertEqual(r.height, (1000.0 / 6 * 2).rounded())
        XCTAssertEqual(r.midX, frame.midX, accuracy: 1)
        XCTAssertEqual(r.midY, frame.midY, accuracy: 1)
    }

    func testMarginsAndGaps() {
        let r = resolve(GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 6), outer: 10, inner: 4)
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 1580, height: 980))
    }

    func testNonSquareGrid() {
        let g = PlacementGrid(rows: 2, cols: 3)
        let r = GridPlacement(col: 1, row: 0, colSpan: 1, rowSpan: 1)
            .resolve(in: frame, grid: g, outerMargin: 0, innerGap: 0)
        XCTAssertEqual(r, CGRect(x: (1600.0 / 3).rounded(), y: 500, width: (1600.0 / 3).rounded(), height: 500))
    }

    func testOutOfBoundsPlacementIsClamped() {
        let r = resolve(GridPlacement(col: 5, row: 5, colSpan: 6, rowSpan: 6))
        XCTAssertEqual(r, frame) // span clamped to grid, origin clamped to 0
    }

    func testRegionDescription() {
        // Recognisable fractions get a name.
        XCTAssertEqual(GridPlacement(col: 0, row: 0, colSpan: 3, rowSpan: 6).regionDescription(in: grid),
                       "Left half")
        XCTAssertEqual(GridPlacement(col: 3, row: 0, colSpan: 3, rowSpan: 6).regionDescription(in: grid),
                       "Right half")
        XCTAssertEqual(GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 6).regionDescription(in: grid),
                       "Full screen")
        XCTAssertEqual(GridPlacement(col: 3, row: 3, colSpan: 3, rowSpan: 3).regionDescription(in: grid),
                       "Bottom-right quarter")
        XCTAssertEqual(GridPlacement(col: 4, row: 0, colSpan: 2, rowSpan: 6).regionDescription(in: grid),
                       "Right third")
        // Anything else falls back to a compact range that fits a narrow column.
        XCTAssertEqual(GridPlacement(col: 0, row: 0, colSpan: 2, rowSpan: 5).regionDescription(in: grid),
                       "C1–2 · R1–5")
        XCTAssertEqual(GridPlacement(col: 2, row: 2, colSpan: 1, rowSpan: 1).regionDescription(in: grid),
                       "C3 · R3")
    }
}

final class PlacementKeymapTests: XCTestCase {

    private func binding(key: Int, mods: UInt = 0, span: Int = 6) -> PlacementBinding {
        PlacementBinding(keyCode: key, modifierFlags: mods, label: "",
                         placement: GridPlacement(col: 0, row: 0, colSpan: span, rowSpan: span))
    }

    func testBindingLookupMatchesBareKey() {
        var map = PlacementKeymap()
        map.bindings = [binding(key: 3), binding(key: 4)]
        XCTAssertEqual(map.binding(forKeyCode: 4, modifierFlags: 0)?.keyCode, 4)
        XCTAssertNil(map.binding(forKeyCode: 99, modifierFlags: 0))
    }

    func testBindingLookupIsModifierSensitive() {
        var map = PlacementKeymap()
        let cmd: UInt = 1 << 20
        map.bindings = [binding(key: 3, mods: cmd)]
        XCTAssertNil(map.binding(forKeyCode: 3, modifierFlags: 0))
        XCTAssertEqual(map.binding(forKeyCode: 3, modifierFlags: cmd)?.keyCode, 3)
    }

    func testConflictDetectionIgnoresSelf() {
        var map = PlacementKeymap()
        let a = binding(key: 3)
        let b = binding(key: 3)
        map.bindings = [a, b]
        XCTAssertTrue(map.hasConflict(keyCode: 3, modifierFlags: 0, excluding: a.id))
        XCTAssertFalse(map.hasConflict(keyCode: 7, modifierFlags: 0, excluding: a.id))
    }

    func testUnassignedBindingsAreExcluded() {
        var map = PlacementKeymap()
        map.bindings = [binding(key: PlacementBinding.unassignedKeyCode)]
        XCTAssertTrue(map.assignedBindings.isEmpty)
        XCTAssertNil(map.binding(forKeyCode: PlacementBinding.unassignedKeyCode, modifierFlags: 0))
    }

    func testCodableRoundTrip() throws {
        var map = PlacementKeymap(grid: PlacementGrid(rows: 4, cols: 8), outerMargin: 6, innerGap: 3)
        map.bindings = [
            PlacementBinding(keyCode: 3, modifierFlags: 1 << 20, label: "left",
                             placement: GridPlacement(col: 0, row: 0, colSpan: 4, rowSpan: 4, display: .index(1))),
            PlacementBinding(keyCode: 4, label: "next",
                             placement: GridPlacement(col: 4, row: 0, colSpan: 4, rowSpan: 4, display: .next)),
        ]
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(PlacementKeymap.self, from: data)
        XCTAssertEqual(decoded, map)
        XCTAssertEqual(decoded.bindings[0].placement.display, .index(1))
        XCTAssertEqual(decoded.bindings[1].placement.display, .next)
    }

    func testDisplayTargetRawIndexMapping() {
        XCTAssertNil(PlacementDisplayTarget.current.rawIndex)
        XCTAssertEqual(PlacementDisplayTarget.next.rawIndex, -1)
        XCTAssertEqual(PlacementDisplayTarget.index(2).rawIndex, 2)
        XCTAssertEqual(PlacementDisplayTarget(rawIndex: nil), .current)
        XCTAssertEqual(PlacementDisplayTarget(rawIndex: -1), .next)
        XCTAssertEqual(PlacementDisplayTarget(rawIndex: 2), .index(2))
    }

    func testGridDimensionsAreClamped() {
        let g = PlacementGrid(rows: 0, cols: 999)
        XCTAssertEqual(g.rows, 1)
        XCTAssertEqual(g.cols, PlacementGrid.maxDimension)
    }
}

final class PlacementConfigRoundTripTests: XCTestCase {

    /// The keymap must survive Rectangle's config export/import.
    func testKeymapSurvivesDefaultsConfigRoundTrip() throws {
        let key = "placementKeymap"
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        var map = PlacementKeymap(grid: PlacementGrid(rows: 6, cols: 6))
        map.bindings = [
            PlacementBinding(keyCode: 3, label: "F",
                             placement: GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 6)),
        ]
        Defaults.placementKeymap.typedValue = map

        guard let json = Defaults.encoded(), let config = Defaults.convert(jsonString: json) else {
            return XCTFail("Config encode/convert failed")
        }
        XCTAssertNotNil(config.defaults[key])

        // Wipe, then reload from the codable default.
        UserDefaults.standard.removeObject(forKey: key)
        if let coded = config.defaults[key] {
            Defaults.placementKeymap.load(from: coded)
        }
        XCTAssertEqual(Defaults.placementKeymap.typedValue, map)
    }
}

final class WindowLayoutTests: XCTestCase {

    private func slot(_ bid: String, _ span: Int) -> LayoutSlot {
        LayoutSlot(appBundleId: bid, placement: GridPlacement(col: 0, row: 0, colSpan: span, rowSpan: span))
    }

    func testLayoutLookupIsKeyAndModifierSensitive() {
        var map = PlacementKeymap()
        let cmd: UInt = 1 << 20
        map.layouts = [
            WindowLayout(keyCode: 13, label: "code", slots: [slot("com.a", 6)]),
            WindowLayout(keyCode: 14, modifierFlags: cmd, label: "write", slots: [slot("com.b", 6)]),
        ]
        XCTAssertEqual(map.layout(forKeyCode: 13, modifierFlags: 0)?.label, "code")
        XCTAssertNil(map.layout(forKeyCode: 14, modifierFlags: 0))
        XCTAssertEqual(map.layout(forKeyCode: 14, modifierFlags: cmd)?.label, "write")
    }

    func testConflictSpansBindingsAndLayouts() {
        var map = PlacementKeymap()
        let b = PlacementBinding(keyCode: 3, placement: GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 6))
        let l = WindowLayout(keyCode: 3, label: "x", slots: [])
        map.bindings = [b]
        map.layouts = [l]
        // the layout's key collides with the binding's key (different ids)
        XCTAssertTrue(map.hasConflict(keyCode: 3, modifierFlags: 0, excluding: l.id))
        XCTAssertTrue(map.hasConflict(keyCode: 3, modifierFlags: 0, excluding: b.id))
        XCTAssertFalse(map.hasConflict(keyCode: 9, modifierFlags: 0, excluding: l.id))
    }

    func testHasAnyAssignedKey() {
        var map = PlacementKeymap()
        XCTAssertFalse(map.hasAnyAssignedKey)
        map.layouts = [WindowLayout(keyCode: 5, slots: [])]
        XCTAssertTrue(map.hasAnyAssignedKey)
    }

    func testKeymapWithLayoutsCodableRoundTrip() throws {
        var map = PlacementKeymap(grid: PlacementGrid(rows: 4, cols: 8), outerMargin: 6, innerGap: 3)
        map.bindings = [PlacementBinding(keyCode: 3, label: "L",
                                        placement: GridPlacement(col: 0, row: 0, colSpan: 4, rowSpan: 4))]
        map.layouts = [WindowLayout(keyCode: 13, modifierFlags: 1 << 19, label: "coding",
                                    slots: [slot("com.microsoft.VSCode", 4), slot("com.apple.Terminal", 2)])]
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(PlacementKeymap.self, from: data)
        XCTAssertEqual(decoded, map)
        XCTAssertEqual(decoded.layouts.first?.slots.count, 2)
    }

    func testOldKeymapJSONWithoutLayoutsStillDecodes() throws {
        let json = #"{"grid":{"rows":6,"cols":6},"outerMargin":0,"innerGap":0,"bindings":[]}"#
        let decoded = try JSONDecoder().decode(PlacementKeymap.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.layouts, [])
    }
}

// MARK: - Drag hit testing

/// The geometry behind dragging a one-off region on the overlay: a point on the
/// pane maps to a cell, and two cells make a block. Both the overlay and the
/// Settings editor go through this, so a regression here would move windows to
/// the wrong place and draw the editor wrong in the same commit.
final class PlacementGridGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
    private let grid = PlacementGrid(rows: 6, cols: 6) // 200 × 100 cells

    private func geometry(margin: CGFloat = 0) -> PlacementGridGeometry {
        PlacementGridGeometry(bounds: bounds, grid: grid, outerMargin: margin)
    }

    func testCornersMapToCornerCells() {
        let g = geometry()
        // Cocoa space: y grows upward, rows count from the top.
        XCTAssertEqual(g.cell(at: CGPoint(x: 1, y: 599)), GridCell(col: 0, row: 0))
        XCTAssertEqual(g.cell(at: CGPoint(x: 1199, y: 599)), GridCell(col: 5, row: 0))
        XCTAssertEqual(g.cell(at: CGPoint(x: 1, y: 1)), GridCell(col: 0, row: 5))
        XCTAssertEqual(g.cell(at: CGPoint(x: 1199, y: 1)), GridCell(col: 5, row: 5))
    }

    func testCenterMapsToCenterCell() {
        XCTAssertEqual(geometry().cell(at: CGPoint(x: 500, y: 350)), GridCell(col: 2, row: 2))
    }

    func testPointOnAGridLineBelongsToTheHigherIndexedCell() {
        let g = geometry()
        // x = 200 is the line between column 0 and column 1.
        XCTAssertEqual(g.cell(at: CGPoint(x: 200, y: 550)).col, 1)
        // y = 500 is the line between row 0 and row 1, counting from the top.
        XCTAssertEqual(g.cell(at: CGPoint(x: 50, y: 500)).row, 1)
    }

    func testPointsOffThePaneClampToEdgeCells() {
        let g = geometry()
        XCTAssertEqual(g.cell(at: CGPoint(x: -500, y: 5000)), GridCell(col: 0, row: 0))
        XCTAssertEqual(g.cell(at: CGPoint(x: 9999, y: -9999)), GridCell(col: 5, row: 5))
    }

    func testOuterMarginShrinksTheGridAndClampsInsideIt() {
        let g = geometry(margin: 60)
        // The usable rect is 1080 × 480, so cells are 180 × 80.
        XCTAssertEqual(g.cellWidth, 180, accuracy: 0.001)
        XCTAssertEqual(g.cellHeight, 80, accuracy: 0.001)
        // A point inside the margin belongs to the nearest edge cell, not to
        // nothing: the margin is a gutter, not a dead zone.
        XCTAssertEqual(g.cell(at: CGPoint(x: 10, y: 590)), GridCell(col: 0, row: 0))
        XCTAssertEqual(g.cell(at: CGPoint(x: 1190, y: 10)), GridCell(col: 5, row: 5))
        // And the first cell inside the margin is still cell zero.
        XCTAssertEqual(g.cell(at: CGPoint(x: 70, y: 530)), GridCell(col: 0, row: 0))
    }

    func testMarginWiderThanThePaneCannotInvertTheUsableRect() {
        let g = PlacementGridGeometry(bounds: bounds, grid: grid, outerMargin: 5000)
        XCTAssertGreaterThanOrEqual(g.usableRect.width, 0)
        XCTAssertGreaterThanOrEqual(g.usableRect.height, 0)
        XCTAssertEqual(g.cell(at: CGPoint(x: 600, y: 300)), GridCell(col: 0, row: 0))
    }

    func testDragIsTheSameBlockWhicheverWayItRan() {
        let a = GridCell(col: 1, row: 1)
        let b = GridCell(col: 3, row: 4)
        let expected = GridPlacement(col: 1, row: 1, colSpan: 3, rowSpan: 4)

        XCTAssertEqual(GridPlacement(anchor: a, focus: b), expected)
        XCTAssertEqual(GridPlacement(anchor: b, focus: a), expected)
        XCTAssertEqual(GridPlacement(anchor: GridCell(col: 3, row: 1), focus: GridCell(col: 1, row: 4)), expected)
        XCTAssertEqual(GridPlacement(anchor: GridCell(col: 1, row: 4), focus: GridCell(col: 3, row: 1)), expected)
    }

    func testClickWithoutMovementIsASingleCell() {
        let cell = GridCell(col: 4, row: 2)
        let p = GridPlacement(anchor: cell, focus: cell)
        XCTAssertEqual(p, GridPlacement(col: 4, row: 2, colSpan: 1, rowSpan: 1))
    }

    func testDragRoundTripsThroughResolveToTheHandBuiltRect() {
        let g = geometry()
        let anchor = g.cell(at: CGPoint(x: 50, y: 580))   // col 0, row 0
        let focus = g.cell(at: CGPoint(x: 450, y: 80))    // col 2, row 5
        let dragged = GridPlacement(anchor: anchor, focus: focus)

        XCTAssertEqual(dragged, GridPlacement(col: 0, row: 0, colSpan: 3, rowSpan: 6))
        XCTAssertEqual(dragged.resolve(in: bounds, grid: grid, outerMargin: 0, innerGap: 0),
                       CGRect(x: 0, y: 0, width: 600, height: 600))
    }

    func testADragAcrossTheTopHalfResolvesHighInCocoaSpace() {
        let g = geometry()
        let anchor = g.cell(at: CGPoint(x: 10, y: 599))   // top-left
        let focus = g.cell(at: CGPoint(x: 1190, y: 310))  // row 2, right edge
        let dragged = GridPlacement(anchor: anchor, focus: focus)

        XCTAssertEqual(dragged, GridPlacement(col: 0, row: 0, colSpan: 6, rowSpan: 3))
        let rect = dragged.resolve(in: bounds, grid: grid, outerMargin: 0, innerGap: 0)
        XCTAssertEqual(rect, CGRect(x: 0, y: 300, width: 1200, height: 300))
    }

    func testDraggedRegionOnAnOffsetScreenLandsOnThatScreen() {
        // A pane on a second display to the right: the drag is computed in the
        // pane's own space, then resolved into the screen's coordinates.
        let paneBounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let screenFrame = CGRect(x: 1920, y: 0, width: 1200, height: 600)
        let g = PlacementGridGeometry(bounds: paneBounds, grid: grid)
        let dragged = GridPlacement(anchor: g.cell(at: CGPoint(x: 610, y: 590)),
                                    focus: g.cell(at: CGPoint(x: 1190, y: 310)))
        let rect = dragged.resolve(in: screenFrame, grid: grid, outerMargin: 0, innerGap: 0)
        XCTAssertEqual(rect, CGRect(x: 1920 + 600, y: 300, width: 600, height: 300))
    }
}

// MARK: - Multi-display placement and live destination preview

final class PlacementOverlayPanelTests: XCTestCase {

    private let targetFrame = CGRect(x: -1600, y: -300, width: 1200, height: 600)
    private let map = PlacementKeymap(grid: PlacementGrid(rows: 6, cols: 6),
                                      outerMargin: 10, innerGap: 8)

    func testPanelFactoryIncludesEveryDisplayEvenWhenFramesMatch() {
        let primary = TestScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let left = TestScreen(id: 2, frame: targetFrame)
        let mirrored = TestScreen(id: 3, frame: primary.frame)
        let screens = [primary, left, mirrored]
        let controller = PlacementModeController()

        let panels = controller.preparePanels(keymap: map, dragEnabled: true, screens: screens)
        defer { panels.forEach { $0.orderOut(nil) } }

        XCTAssertEqual(panels.count, screens.count)
        for (panel, screen) in zip(panels, screens) {
            XCTAssertTrue(panel.targetScreen === screen)
            XCTAssertEqual(panel.targetFrame, screen.adjustedVisibleFrame(ignoreCombinedDisplays: true))
            XCTAssertTrue(panel.matches(screen: screen, frame: screen.adjustedVisibleFrame(ignoreCombinedDisplays: true),
                                        keymap: map, dragEnabled: true))
            XCTAssertNil(panel.dragPreview, "Preparing placement selectors should not allocate previews")
        }
        XCTAssertTrue(controller.preparePanels(keymap: map, dragEnabled: true, screens: []).isEmpty)
    }

    func testPanelMatchingUsesDisplayIdentityAndPlacementConfiguration() {
        let screen = TestScreen(id: 1, frame: targetFrame)
        let panel = PlacementOverlayPanel(screen: screen, frame: targetFrame,
                                          keymap: map, dragEnabled: true)
        let sameDisplay = TestScreen(id: 1, frame: targetFrame)
        let otherDisplay = TestScreen(id: 2, frame: targetFrame)

        XCTAssertTrue(panel.matches(screen: sameDisplay, frame: targetFrame,
                                    keymap: map, dragEnabled: true))
        XCTAssertFalse(panel.matches(screen: otherDisplay, frame: targetFrame,
                                     keymap: map, dragEnabled: true))
        XCTAssertFalse(panel.matches(screen: screen, frame: targetFrame.offsetBy(dx: 1, dy: 0),
                                     keymap: map, dragEnabled: true))
        XCTAssertFalse(panel.matches(screen: screen, frame: targetFrame,
                                     keymap: PlacementKeymap(), dragEnabled: true))
        XCTAssertFalse(panel.matches(screen: screen, frame: targetFrame,
                                     keymap: map, dragEnabled: false))
    }

    func testDragPreviewsExactDestinationAndHidesOnRelease() throws {
        let panel = makePanel()
        defer { panel.clearDrag(); panel.orderOut(nil) }
        let view = try XCTUnwrap(panel.contentView as? PlacementPanelView)
        var committed: [GridPlacement] = []
        panel.onDragCommitted = { committed.append($0) }

        XCTAssertNil(panel.dragPreview)
        view.mouseDown(with: try event(.leftMouseDown, cell: GridCell(col: 0, row: 0), in: panel))
        let preview = try XCTUnwrap(panel.dragPreview)
        XCTAssertTrue(preview.isVisible)
        XCTAssertEqual(preview.frame, CGRect(x: -1590, y: 200, width: 190, height: 90))
        XCTAssertTrue(preview.ignoresMouseEvents)
        XCTAssertFalse(preview.canBecomeKey)
        XCTAssertFalse(preview.canBecomeMain)
        XCTAssertTrue(preview.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(preview.styleMask.contains(.titled))
        XCTAssertLessThan(preview.level.rawValue, panel.level.rawValue)

        view.mouseDragged(with: try event(.leftMouseDragged, cell: GridCell(col: 2, row: 2), in: panel))
        let selected = GridPlacement(col: 0, row: 0, colSpan: 3, rowSpan: 3)
        let destination = CGRect(x: -1590, y: 4, width: 586, height: 286)
        XCTAssertTrue(panel.dragPreview === preview)
        XCTAssertEqual(view.dragSelection, selected)
        XCTAssertEqual(panel.destinationRect(for: selected), destination)
        XCTAssertEqual(preview.frame, destination,
                       "The full-size preview must honor the destination display, margins, and gaps")

        view.mouseUp(with: try event(.leftMouseUp, cell: GridCell(col: 2, row: 2), in: panel))
        XCTAssertEqual(committed, [selected])
        XCTAssertFalse(preview.isVisible)
    }

    func testClearingDragCancelsAnchorSoLaterEventsCannotCommitIt() throws {
        let panel = makePanel()
        defer { panel.clearDrag(); panel.orderOut(nil) }
        let view = try XCTUnwrap(panel.contentView as? PlacementPanelView)
        var committed: [GridPlacement] = []
        panel.onDragCommitted = { committed.append($0) }
        view.mouseDown(with: try event(.leftMouseDown, cell: GridCell(col: 0, row: 0), in: panel))
        let preview = try XCTUnwrap(panel.dragPreview)

        panel.clearDrag()
        XCTAssertNil(view.dragSelection)
        XCTAssertFalse(preview.isVisible)

        view.mouseDragged(with: try event(.leftMouseDragged, cell: GridCell(col: 5, row: 5), in: panel))
        view.mouseUp(with: try event(.leftMouseUp, cell: GridCell(col: 5, row: 5), in: panel))
        XCTAssertNil(view.dragSelection)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertFalse(preview.isVisible)
    }

    func testReuseAndDismissHidePreviewAndCancelInFlightDrag() throws {
        let panel = makePanel()
        defer { panel.clearDrag(); panel.orderOut(nil) }
        let view = try XCTUnwrap(panel.contentView as? PlacementPanelView)
        var commitCount = 0
        panel.onDragCommitted = { _ in commitCount += 1 }
        let down = try event(.leftMouseDown, cell: GridCell(col: 0, row: 0), in: panel)
        let drag = try event(.leftMouseDragged, cell: GridCell(col: 5, row: 5), in: panel)
        let up = try event(.leftMouseUp, cell: GridCell(col: 5, row: 5), in: panel)

        view.mouseDown(with: down)
        let preview = try XCTUnwrap(panel.dragPreview)
        panel.prepareForReuse()
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(view.dragSelection)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        XCTAssertEqual(commitCount, 0)

        view.mouseDown(with: down)
        XCTAssertTrue(panel.dragPreview?.isVisible == true)
        let dismissed = expectation(description: "Placement selector dismissed")
        panel.dismiss { dismissed.fulfill() }
        XCTAssertFalse(panel.dragPreview?.isVisible == true)
        XCTAssertNil(view.dragSelection)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        XCTAssertEqual(commitCount, 0)
        wait(for: [dismissed], timeout: 1)
    }

    func testDisabledDraggingNeverCreatesPreviewOrCommits() throws {
        let panel = makePanel(dragEnabled: false)
        let view = try XCTUnwrap(panel.contentView as? PlacementPanelView)
        var commitCount = 0
        panel.onDragCommitted = { _ in commitCount += 1 }

        view.mouseDown(with: try event(.leftMouseDown, cell: GridCell(col: 0, row: 0), in: panel))
        view.mouseDragged(with: try event(.leftMouseDragged, cell: GridCell(col: 5, row: 5), in: panel))
        view.mouseUp(with: try event(.leftMouseUp, cell: GridCell(col: 5, row: 5), in: panel))

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertNil(view.dragSelection)
        XCTAssertNil(panel.dragPreview)
        XCTAssertEqual(commitCount, 0)
    }

    private func makePanel(dragEnabled: Bool = true) -> PlacementOverlayPanel {
        PlacementOverlayPanel(screen: TestScreen(id: 2, frame: targetFrame), frame: targetFrame,
                              keymap: map, dragEnabled: dragEnabled)
    }

    private func event(_ type: NSEvent.EventType, cell: GridCell,
                       in panel: PlacementOverlayPanel) throws -> NSEvent {
        let view = try XCTUnwrap(panel.contentView)
        // The selector has 12-point padding, a 30-point header, and a 20-point footer.
        let grid = CGRect(x: 12, y: 32, width: view.bounds.width - 24, height: view.bounds.height - 74)
        let point = CGPoint(x: grid.minX + (CGFloat(cell.col) + 0.5) * grid.width / 6,
                            y: grid.maxY - (CGFloat(cell.row) + 0.5) * grid.height / 6)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    private final class TestScreen: NSScreen {
        private let displayID: CGDirectDisplayID
        private let testFrame: CGRect

        init(id: CGDirectDisplayID, frame: CGRect) {
            displayID = id
            testFrame = frame
            super.init()
        }

        override var frame: NSRect { testFrame }
        override var visibleFrame: NSRect { testFrame }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var hash: Int { ObjectIdentifier(self).hashValue }
        override var deviceDescription: [NSDeviceDescriptionKey: Any] {
            [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
        }

        override func isEqual(_ object: Any?) -> Bool {
            (object as AnyObject?) === self
        }
    }
}

// MARK: - Bundle identifier migration

/// Snappy 1.0 shipped as `com.travismarceau.snappy`. The copy that carries a
/// 1.0 user's settings into the new domain runs once, before anything reads
/// `Defaults`, and must never overwrite a value the user has already set here.
final class LegacyDefaultsMigrationTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SnappyMigrationTests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // The legacy domain is shared, so leave it as we found it.
        suite.removePersistentDomain(forName: LegacyDefaultsMigration.legacyDomain)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: LegacyDefaultsMigration.legacyDomain)
        suite.removePersistentDomain(forName: suiteName)
    }

    private func seedLegacy(_ values: [String: Any]) {
        suite.setPersistentDomain(values, forName: LegacyDefaultsMigration.legacyDomain)
    }

    func testCopiesLegacyValuesIntoTheNewDomain() {
        seedLegacy(["placementPaneTimeout": 9, "placementPaneSticky": true])

        LegacyDefaultsMigration.run(userDefaults: suite, bundleId: "com.simarholonipaa.snappy")

        XCTAssertEqual(suite.integer(forKey: "placementPaneTimeout"), 9)
        XCTAssertTrue(suite.bool(forKey: "placementPaneSticky"))
        XCTAssertTrue(suite.bool(forKey: LegacyDefaultsMigration.completedKey))
    }

    func testDoesNotOverwriteAValueAlreadySetInTheNewDomain() {
        seedLegacy(["placementPaneTimeout": 9])
        suite.set(3, forKey: "placementPaneTimeout")

        LegacyDefaultsMigration.run(userDefaults: suite, bundleId: "com.simarholonipaa.snappy")

        XCTAssertEqual(suite.integer(forKey: "placementPaneTimeout"), 3)
    }

    func testRunsOnlyOnce() {
        seedLegacy(["placementPaneTimeout": 9])
        LegacyDefaultsMigration.run(userDefaults: suite, bundleId: "com.simarholonipaa.snappy")

        // The user then changes their mind in the new app; a second launch must
        // not drag the old value back over it.
        suite.set(3, forKey: "placementPaneTimeout")
        LegacyDefaultsMigration.run(userDefaults: suite, bundleId: "com.simarholonipaa.snappy")

        XCTAssertEqual(suite.integer(forKey: "placementPaneTimeout"), 3)
    }

    func testDoesNothingWhenRunningAsTheLegacyBundle() {
        seedLegacy(["placementPaneTimeout": 9])

        LegacyDefaultsMigration.run(userDefaults: suite,
                                    bundleId: LegacyDefaultsMigration.legacyDomain)

        XCTAssertNil(suite.object(forKey: "placementPaneTimeout"))
        XCTAssertFalse(suite.bool(forKey: LegacyDefaultsMigration.completedKey))
    }

    func testMarksItselfCompleteWhenThereIsNothingToCopy() {
        LegacyDefaultsMigration.run(userDefaults: suite, bundleId: "com.simarholonipaa.snappy")

        XCTAssertTrue(suite.bool(forKey: LegacyDefaultsMigration.completedKey))
    }
}

// MARK: - Diagnostics

final class DiagnosticsTests: XCTestCase {

    func testEventTapCountersAreIsolatedPerMonitor() {
        let placement = EventTapDiagnostics()
        let snapping = EventTapDiagnostics()

        placement.record(.keyDown)
        snapping.record(.leftMouseDown)
        snapping.record(.tapDisabledByTimeout)

        XCTAssertEqual(placement.snapshot.callbackInvocations, 1)
        XCTAssertEqual(placement.snapshot.disableNotices, 0)
        XCTAssertEqual(snapping.snapshot.callbackInvocations, 2)
        XCTAssertEqual(snapping.snapshot.disableNotices, 1)
    }

    func testInstallationLocationRedactsHomeDirectory() {
        let home = "/Users/private-name"

        XCTAssertEqual(
            Diagnostics.installationLocation(
                for: "/Users/private-name/Downloads/Snappy.app",
                home: home),
            "inside the user’s home directory")
        XCTAssertEqual(
            Diagnostics.installationLocation(
                for: "/Users/private-name/Applications/Snappy.app",
                home: home),
            "~/Applications")
    }

    func testIssueTitleUsesMarketingVersionAndBuild() {
        XCTAssertEqual(
            Diagnostics.issueTitle(info: [
                "CFBundleShortVersionString": "1.2",
                "CFBundleVersion": "3",
            ]),
            "[1.2 build 3] ")
    }
}
