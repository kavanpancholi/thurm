import AppKit
import XCTest
@testable import Thurm

/// A sidebar toggle resizes each terminal's grid once, after the slide, never at its in-between
/// widths: the program would reflow its output at every step.
final class SidebarGridHoldTests: XCTestCase {
    private let manager = SessionManager.shared
    private var savedConfig: AppConfig!
    private var controllers: [TerminalWindowController] = []
    private var savedFontSettings: (() -> (any FontSettings, CGFloat))?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedConfig = manager.config
        let config = AppConfig()
        manager.config = config
        savedFontSettings = FontShaper.settings
        FontShaper.settings = { (config, 14) }
        FontShaper.invalidateAll()
    }

    override func tearDown() {
        for c in controllers {
            c.closingWithoutConfirmation = true
            c.window?.close()
        }
        controllers = []
        FontShaper.settings = savedFontSettings
        FontShaper.invalidateAll()
        manager.config = savedConfig
        super.tearDown()
    }

    private func toggle(_ split: TabSplitViewController) {
        split.toggleSidebarAnimated()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !split.sidebar.holdReloads },
                                                object: nil)
        wait(for: [settled], timeout: 3)
    }

    /// A toggle during a pane move settles the move first. Settling it on the slide's first
    /// width instead would release the sidebar's hold, and every later width reached the PTY.
    func testToggleDuringPaneMoveKeepsGridsUntilTheSlideEnds() throws {
        let pane = PaneKey(localHost, 1)
        let c = manager.makeController(root: .leaf(pane), focused: pane, zoomed: nil, title: nil,
                                       frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        controllers.append(c)
        let split = try XCTUnwrap(c.tabSplit)
        let initiallyCollapsed = split.sidebarCollapsed
        defer { if split.sidebarCollapsed != initiallyCollapsed { toggle(split) } }
        let content = c.content
        content.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(content.views[pane])
        view.metricsChanged()
        XCTAssertGreaterThan(view.cols, 0)

        content.split(newPane: PaneKey(localHost, 2), direction: .right)
        split.toggleSidebarAnimated()
        let held = (view.cols, view.rows)
        XCTAssertTrue(view.holdGridSize)
        // In-between widths of the slide.
        let start = content.frame.width
        for step in [40.0, 80.0, 120.0] {
            content.setFrameSize(NSSize(width: start + (initiallyCollapsed ? -step : step),
                                        height: content.frame.height))
            XCTAssertTrue(view.holdGridSize, "width \(content.frame.width)")
            XCTAssertEqual(view.cols, held.0, "width \(content.frame.width)")
            XCTAssertEqual(view.rows, held.1)
        }

        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !split.sidebar.holdReloads },
                                                object: nil)
        wait(for: [settled], timeout: 3)
        XCTAssertFalse(view.holdGridSize)
        XCTAssertEqual(split.sidebarCollapsed, !initiallyCollapsed)
        if initiallyCollapsed {
            XCTAssertLessThan(view.cols, held.0, "the shown sidebar narrows the grid once it settles")
        } else {
            XCTAssertGreaterThan(view.cols, held.0, "the hidden sidebar widens the grid once it settles")
        }
    }
}
