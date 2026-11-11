import Metal
import XCTest
@testable import Thurm

final class MinimizedCardTests: XCTestCase {
    private func key(_ id: UInt64) -> PaneKey { .local(id) }

    private func requireMetal() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        _ = try XCTUnwrap(MetalContext.shared, "Metal pipeline initialization failed")
    }

    private func tab(minimized: Bool = false) -> TabContentView {
        let root = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(key(1)), second: .leaf(key(2)))
        let content = TabContentView(root: root, focused: key(3), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.2, 0.2, 0.5, 0.5],
                                                             minimized: minimized)])
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        return content
    }

    func testTabLayoutCodesMinimizedCards() throws {
        let json = #"{"id":2,"frame":[0.1,0.2,0.5,0.5],"minimized":true}"#
        let card = try JSONDecoder().decode(FloatingPane.self, from: Data(json.utf8))
        XCTAssertTrue(card.minimized)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(card), as: UTF8.self).contains("\"minimized\":true"))
        XCTAssertEqual(FloatingCard(card).saved, card)
        let shown = FloatingPane(pane: key(2), frame: [0.1, 0.2, 0.5, 0.5])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains("minimized"))
        let older = try JSONDecoder().decode(FloatingPane.self, from: Data(#"{"id":2,"frame":[0.1,0.2,0.5,0.5]}"#.utf8))
        XCTAssertFalse(older.minimized)
    }

    func testMinimizingHidesTheCardAndFocusesTheSplits() throws {
        try requireMetal()
        let content = tab()
        defer { content.detachAll() }
        XCTAssertEqual(content.focusedPane, key(3))
        content.setMinimized(key(3), true)
        XCTAssertTrue(content.isMinimized(key(3)))
        XCTAssertTrue(content.isCardHidden(key(3)))
        XCTAssertTrue(content.root.contains(content.focusedPane))
        XCTAssertEqual(content.visiblePaneIds, [key(1), key(2)])
        XCTAssertTrue(content.contains(key(3)), "its program keeps running in the tab")
        XCTAssertEqual(content.tabLayout(title: nil).floating?.first?.minimized, true)
    }

    func testFocusingAMinimizedCardRestoresIt() throws {
        try requireMetal()
        let content = tab(minimized: true)
        defer { content.detachAll() }
        XCTAssertTrue(content.root.contains(content.focusedPane), "a minimized card does not take the focus")
        content.focus(key(3))
        XCTAssertFalse(content.isMinimized(key(3)))
        XCTAssertEqual(content.focusedPane, key(3))
        XCTAssertEqual(content.visiblePaneIds, [key(1), key(2), key(3)])
        XCTAssertNil(content.tabLayout(title: nil).floating?.first.flatMap { $0.minimized ? $0 : nil })
    }

    func testClosingAMinimizedCardRemovesIt() throws {
        try requireMetal()
        let content = tab(minimized: true)
        defer { content.detachAll() }
        XCTAssertFalse(content.remove(pane: key(3)))
        XCTAssertFalse(content.contains(key(3)))
        XCTAssertTrue(content.floating.isEmpty)
    }

    func testHidingAndShowingCardsKeepsMinimizedOnesMinimized() throws {
        try requireMetal()
        let content = tab()
        defer { content.detachAll() }
        content.setMinimized(key(3), true)
        content.setFloatingHidden(true)
        content.setFloatingHidden(false)
        XCTAssertTrue(content.isMinimized(key(3)))
        XCTAssertTrue(content.root.contains(content.focusedPane))
    }
}
