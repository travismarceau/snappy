/// PlacementTests.swift

import XCTest
@testable import Rectangle

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
        XCTAssertEqual(GridPlacement(col: 0, row: 0, colSpan: 3, rowSpan: 6).regionDescription(in: grid),
                       "cols 1–3 / rows 1–6")
        XCTAssertEqual(GridPlacement(col: 2, row: 2, colSpan: 1, rowSpan: 1).regionDescription(in: grid),
                       "col 3 / row 3")
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
