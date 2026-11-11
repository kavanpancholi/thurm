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

    private func minimizedTab(cards: Int, width: CGFloat) -> TabContentView {
        let floating = (0..<cards).map { i in
            FloatingPane(pane: key(UInt64(10 + i)), frame: [0.2, 0.2, 0.5, 0.5], minimized: true)
        }
        let content = TabContentView(root: .leaf(key(1)), focused: key(1), zoomed: nil, floating: floating)
        content.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        content.layoutPanes()
        return content
    }

    private func setTitle(_ title: String, of pane: PaneKey) {
        SessionManager.shared.panes[pane] = PaneInfo(json: ["id": NSNumber(value: pane.id), "title": title, "alive": true])
    }

    func testChipsWrapToStayInsideANarrowTab() throws {
        try requireMetal()
        for i in 0..<6 { setTitle("a long running build \(i)", of: key(UInt64(10 + i))) }
        defer { for i in 0..<6 { SessionManager.shared.panes[key(UInt64(10 + i))] = nil } }
        let content = minimizedTab(cards: 6, width: 360)
        defer { content.detachAll() }
        let bar = content.minimizedBar
        XCTAssertEqual(bar.chips.count, 6)
        XCTAssertGreaterThanOrEqual(bar.frame.minX, 0)
        XCTAssertLessThanOrEqual(bar.frame.maxX, 360)
        XCTAssertGreaterThan(bar.frame.height, MinimizedCardChip.height, "the chips wrap into rows")
        for chip in bar.chips {
            XCTAssertTrue(bar.bounds.contains(chip.frame), "every chip stays on screen")
            XCTAssertGreaterThan(chip.frame.width, 0)
        }
        let frames = bar.chips.map(\.frame)
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
        }
    }

    func testTheChipBarGrowsWithAMinimizedPanesTitle() throws {
        try requireMetal()
        setTitle("vim", of: key(10))
        defer { SessionManager.shared.panes[key(10)] = nil }
        let content = minimizedTab(cards: 1, width: 1000)
        defer { content.detachAll() }
        let before = content.minimizedBar.frame.width
        setTitle("cargo test --workspace", of: key(10))
        content.refreshHeaders()
        XCTAssertGreaterThan(content.minimizedBar.frame.width, before)
        XCTAssertEqual(content.minimizedBar.frame.maxX, content.paneArea.maxX - 12, accuracy: 0.5)
    }

    func testChipsAreButtonsThatRestoreTheirCard() throws {
        try requireMetal()
        setTitle("log tail", of: key(10))
        defer { SessionManager.shared.panes[key(10)] = nil }
        let content = minimizedTab(cards: 1, width: 1000)
        defer { content.detachAll() }
        let chip = try XCTUnwrap(content.minimizedBar.chips.first)
        XCTAssertTrue(chip.isAccessibilityElement())
        XCTAssertEqual(chip.accessibilityRole(), .button)
        XCTAssertEqual(chip.accessibilityLabel(), "Restore log tail")
        XCTAssertTrue(chip.canBecomeKeyView)
        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertFalse(content.isMinimized(key(10)))
        XCTAssertEqual(content.focusedPane, key(10))
    }

    func testChipsThatDoNotFitGoBehindAMenu() throws {
        try requireMetal()
        let count = 30
        for i in 0..<count { setTitle("build \(i)", of: key(UInt64(10 + i))) }
        defer { for i in 0..<count { SessionManager.shared.panes[key(UInt64(10 + i))] = nil } }
        let floating = (0..<count).map { i in
            FloatingPane(pane: key(UInt64(10 + i)), frame: [0.2, 0.2, 0.5, 0.5], minimized: true)
        }
        let content = TabContentView(root: .leaf(key(1)), focused: key(1), zoomed: nil, floating: floating)
        content.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        content.layoutPanes()
        defer { content.detachAll() }
        let bar = content.minimizedBar
        XCTAssertGreaterThanOrEqual(bar.frame.minY, content.paneArea.minY, "no row above the tab")
        XCTAssertLessThanOrEqual(bar.frame.height, 300 / 2)
        XCTAssertFalse(bar.overflow.isHidden)
        let shown = bar.chips.filter { !$0.isHidden }
        XCTAssertEqual(shown.count + bar.overflowPanes.count, count, "every pane has a chip or a menu item")
        for view in shown as [NSView] + [bar.overflow] {
            XCTAssertTrue(bar.bounds.contains(view.frame))
        }
        let menu = bar.overflowMenu()
        XCTAssertEqual(menu.items.map(\.title), bar.overflowPanes.map { "build \($0.id - 10)" })
        let last = try XCTUnwrap(bar.overflowPanes.last)
        bar.restoreFromMenu(try XCTUnwrap(menu.items.last))
        XCTAssertFalse(content.isMinimized(last))
        XCTAssertEqual(content.focusedPane, last)
    }
}
