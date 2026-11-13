import Metal
import XCTest
@testable import Thurm

final class EdgeMoveTests: XCTestCase {
    private func key(_ id: UInt64) -> PaneKey { .local(id) }
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func requireMetal() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        _ = try XCTUnwrap(MetalContext.shared, "Metal pipeline initialization failed")
    }

    private func sideBySide() -> SplitNode {
        .split(axis: .horizontal, ratio: 0.5, first: .leaf(key(1)), second: .leaf(key(2)))
    }

    func testThePointerPicksTheNearestEdgeInsideTheArea() {
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 10, y: 300), in: area), .left)
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 990, y: 300), in: area), .right)
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 500, y: 8), in: area), .up)
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 500, y: 595), in: area), .down)
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 5, y: 20), in: area), .left, "the nearer edge in a corner")
        XCTAssertEqual(FloatingGeometry.edge(at: CGPoint(x: 25, y: 4), in: area), .up)
        XCTAssertNil(FloatingGeometry.edge(at: CGPoint(x: 500, y: 300), in: area))
        XCTAssertNil(FloatingGeometry.edge(at: CGPoint(x: 100, y: 300), in: area))
        for outside in [CGPoint(x: -20, y: 300), CGPoint(x: 1020, y: 300), CGPoint(x: 500, y: -20), CGPoint(x: 500, y: 620)] {
            XCTAssertNil(FloatingGeometry.edge(at: outside, in: area), "\(outside) is outside the tab")
        }
    }

    func testEachEdgePreviewsHalfTheArea() {
        XCTAssertEqual(FloatingGeometry.edgeRect(.left, in: area), CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(FloatingGeometry.edgeRect(.right, in: area), CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(FloatingGeometry.edgeRect(.up, in: area), CGRect(x: 0, y: 0, width: 1000, height: 300))
        XCTAssertEqual(FloatingGeometry.edgeRect(.down, in: area), CGRect(x: 0, y: 300, width: 1000, height: 300))
    }

    func testWrappingPutsAPaneBesideTheWholeTree() {
        let tree = sideBySide()
        let cases: [(SplitDirName, SplitAxis, Bool, [UInt64])] = [
            (.left, .horizontal, false, [3, 1, 2]), (.right, .horizontal, true, [1, 2, 3]),
            (.up, .vertical, false, [3, 1, 2]), (.down, .vertical, true, [1, 2, 3]),
        ]
        for (edge, axis, second, order) in cases {
            let wrapped = tree.wrapping(key(3), edge: edge)
            XCTAssertEqual(wrapped.panes, order.map(key), "\(edge)")
            let side = wrapped.side(of: key(3))
            XCTAssertEqual(side?.axis, axis, "\(edge)")
            XCTAssertEqual(side?.second, second, "\(edge)")
            guard case .split(_, let ratio, _, _) = wrapped else { return XCTFail("\(edge) is not a split") }
            XCTAssertEqual(ratio, 0.5, accuracy: 0.0001)
        }
    }

    func testAFloatingCardDroppedAtAnEdgeBecomesThatHalfOfTheTab() throws {
        try requireMetal()
        let content = TabContentView(root: .leaf(key(1)), focused: key(3), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.2, 0.2, 0.4, 0.4])])
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        content.moveToEdge(key(3), .right)
        XCTAssertFalse(content.isFloating(key(3)))
        XCTAssertTrue(content.floating.isEmpty)
        XCTAssertEqual(content.root.panes, [key(1), key(3)])
        XCTAssertEqual(content.root.side(of: key(3))?.axis, .horizontal)
        XCTAssertEqual(content.root.side(of: key(3))?.second, true)
        XCTAssertNil(content.tabLayout(title: nil).floating)
    }

    func testASplitMovesToAnotherEdge() throws {
        try requireMetal()
        let content = TabContentView(root: sideBySide(), focused: key(1), zoomed: nil)
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        XCTAssertTrue(content.canMoveSplit(key(1)))
        content.moveToEdge(key(1), .down)
        XCTAssertEqual(content.root.panes, [key(2), key(1)])
        XCTAssertEqual(content.root.side(of: key(1))?.axis, .vertical)
        XCTAssertEqual(content.root.side(of: key(1))?.second, true)
    }

    func testASplitDroppedOnAnotherPaneSplitsIt() throws {
        try requireMetal()
        let content = TabContentView(root: sideBySide(), focused: key(1), zoomed: nil)
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        content.move(key(1), nextTo: key(2), direction: .down, share: nil)
        XCTAssertEqual(content.root.panes, [key(2), key(1)])
        XCTAssertEqual(content.root.side(of: key(1))?.axis, .vertical)
        XCTAssertEqual(content.root.side(of: key(1))?.second, true)
    }

    func testTheOnlyPaneOfTheSplitsStaysPut() throws {
        try requireMetal()
        let content = TabContentView(root: .leaf(key(1)), focused: key(1), zoomed: nil)
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        XCTAssertFalse(content.canMoveSplit(key(1)))
        content.moveToEdge(key(1), .left)
        XCTAssertEqual(content.root.panes, [key(1)])
        guard case .leaf = content.root else { return XCTFail("the lone pane got split") }
    }
}
