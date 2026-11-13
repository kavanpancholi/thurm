import AppKit
import Metal
import XCTest
@testable import Thurm

final class PaneDragTests: XCTestCase {
    private let first = PaneKey.local(1)
    private let second = PaneKey.local(2)
    private let card = PaneKey.local(3)
    private let moveModifiers: NSEvent.ModifierFlags = [.command, .option]

    private func withContent(headers: Bool = true, floating: Bool = false, single: Bool = false,
                             _ body: (TabContentView, NSWindow) throws -> Void) throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal is unavailable")
        _ = NSApplication.shared
        let savedConfig = SessionManager.shared.config
        SessionManager.shared.config.paneHeaders = headers
        defer { SessionManager.shared.config = savedConfig }
        let root: SplitNode = single ? .leaf(first) :
            .split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
        let content = TabContentView(root: root, focused: second, zoomed: nil,
                                     floating: floating ? [FloatingPane(pane: card, frame: [0.2, 0.2, 0.4, 0.4])] : [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.layoutPanes()
        defer { content.detachAll(); window.close() }
        try body(content, window)
    }

    private func drag(_ pane: PaneKey, in content: TabContentView, window: NSWindow,
                      modifiers: NSEvent.ModifierFlags, end: NSPoint? = nil,
                      cancel: Bool = false, clickOnly: Bool = false, header: Bool = false) throws {
        let view = try XCTUnwrap(content.views[pane])
        let start = NSPoint(x: view.frame.midX, y: view.frame.midY)
        let destination = end ?? NSPoint(x: content.paneArea.maxX - 20, y: content.paneArea.midY)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: content.convert(point, to: nil), modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        if !clickOnly { NSApp.postEvent(mouse(.leftMouseDragged, at: destination), atStart: false) }
        if cancel {
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                            isARepeat: false, keyCode: 53)!, atStart: false)
        }
        NSApp.postEvent(mouse(.leftMouseUp, at: clickOnly ? start : destination), atStart: false)
        if header {
            let title = try XCTUnwrap(content.subviews.compactMap { $0 as? PaneHeader }.first { $0.pane == pane })
            title.mouseDown(with: mouse(.leftMouseDown, at: start))
        } else {
            view.mouseDown(with: mouse(.leftMouseDown, at: start))
        }
        // Send events that the drag did not consume through the normal terminal input path.
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast,
                                         inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { view.mouseUp(with: event) }
            else { view.mouseDragged(with: event) }
        }
    }

    func testCommandOptionDragMovesASplitWithOrWithoutHeaders() throws {
        for headers in [true, false] {
            try withContent(headers: headers) { content, window in
                let frame = window.frame
                try drag(first, in: content, window: window, modifiers: moveModifiers)
                XCTAssertEqual(content.root.panes, [second, first])
                XCTAssertEqual(content.focusedPane, first)
                XCTAssertEqual(window.frame, frame)
                XCTAssertTrue(window.isMovable)
            }
        }
    }

    func testCommandOptionDragDropsBesideAnotherPane() throws {
        try withContent { content, window in
            let target = try XCTUnwrap(content.views[second]).frame
            try drag(first, in: content, window: window, modifiers: moveModifiers,
                     end: NSPoint(x: target.midX, y: target.maxY - target.height / 4))
            XCTAssertEqual(content.root.panes, [second, first])
            XCTAssertEqual(content.root.side(of: first)?.axis, .vertical)
            XCTAssertEqual(content.root.side(of: first)?.second, true)
        }
    }

    func testOtherModifiersDoNotMoveThePane() throws {
        let modifiers: [NSEvent.ModifierFlags] = [[], .command, .option, [.control, .option],
                                                 [.command, .option, .shift], [.command, .option, .control]]
        for flags in modifiers {
            try withContent { content, window in
                try drag(first, in: content, window: window, modifiers: flags)
                XCTAssertEqual(content.root.panes, [first, second], "Modifiers: \(flags.rawValue)")
            }
        }
    }

    func testClickWithoutDraggingKeepsTheLayout() throws {
        try withContent(floating: true) { content, window in
            let cards = content.floating
            for pane in [first, card] {
                try drag(pane, in: content, window: window, modifiers: moveModifiers, clickOnly: true)
                XCTAssertEqual(content.root.panes, [first, second])
                XCTAssertEqual(content.floating, cards)
            }
        }
    }

    func testTheOnlySplitPaneStaysPut() throws {
        try withContent(single: true) { content, window in
            try drag(first, in: content, window: window, modifiers: moveModifiers)
            XCTAssertEqual(content.root.panes, [first])
        }
    }

    func testEscapeCancelsSplitAndFloatingDrags() throws {
        for floating in [false, true] {
            try withContent(floating: floating) { content, window in
                let pane = floating ? card : first
                let cards = content.floating
                try drag(pane, in: content, window: window, modifiers: moveModifiers, cancel: true)
                XCTAssertEqual(content.root.panes, [first, second])
                XCTAssertEqual(content.floating, cards)
                try drag(pane, in: content, window: window, modifiers: moveModifiers)
                XCTAssertEqual(content.root.panes, floating ? [first, second, card] : [second, first])
                XCTAssertFalse(content.isFloating(pane))
            }
        }
    }

    func testFloatingBodyDragUsesTheWholeTabEdge() throws {
        try withContent(floating: true) { content, window in
            try drag(card, in: content, window: window, modifiers: moveModifiers)
            guard case .split(.horizontal, let ratio, let left, let right) = content.root else {
                return XCTFail("The card did not dock at the right edge")
            }
            XCTAssertEqual(ratio, 0.5)
            XCTAssertEqual(left.panes, [first, second])
            XCTAssertEqual(right.panes, [card])
        }
    }

    func testSplitHeaderDoesNotStartAPaneDrag() throws {
        try withContent { content, window in
            try drag(first, in: content, window: window, modifiers: [], header: true)
            XCTAssertEqual(content.root.panes, [first, second])
            XCTAssertTrue(window.isMovable)
        }
    }

    func testFloatingHeaderStillDragsWithoutModifiers() throws {
        try withContent(floating: true) { content, window in
            try drag(card, in: content, window: window, modifiers: [], header: true)
            XCTAssertFalse(content.isFloating(card))
            XCTAssertEqual(content.root.panes, [first, second, card])
        }
    }
}
