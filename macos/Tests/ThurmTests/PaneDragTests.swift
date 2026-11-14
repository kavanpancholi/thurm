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
                      modifiers: NSEvent.ModifierFlags, start: NSPoint? = nil, end: NSPoint? = nil,
                      cancel: Bool = false, clickOnly: Bool = false, header: Bool = false) throws {
        let view = try XCTUnwrap(content.views[pane])
        let start = start ?? NSPoint(x: view.frame.midX, y: view.frame.midY)
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

    /// Shows `path` on the third row of `pane` and records the files it asks Quick Look to open.
    /// Returns a point on the path and one on the blank row below it, in `content`'s coordinates.
    private func show(_ path: String, in content: TabContentView, pane: PaneKey,
                      previews: @escaping (URL) -> Void) throws -> (onPath: NSPoint, blank: NSPoint) {
        let view = try XCTUnwrap(content.views[pane])
        view.accessibilitySnapshot.show(lines: ["", "", "  " + path, ""], cols: path.count + 4)
        view.openPreview = previews
        let cell = view.accessibilityCellSize
        let padding = view.accessibilityPadding
        func point(col: Int, row: Int) -> NSPoint {
            view.convert(NSPoint(x: padding.x + (CGFloat(col) + 0.5) * cell.width,
                                 y: padding.y + (CGFloat(row) + 0.5) * cell.height), to: content)
        }
        let points = (onPath: point(col: 4, row: 2), blank: point(col: 4, row: 3))
        // The negative cases mean nothing unless the pointer finds the path.
        XCTAssertEqual(view.fileReference(at: view.convert(points.onPath, from: content)), .path(path))
        XCTAssertNil(view.fileReference(at: view.convert(points.blank, from: content)))
        return points
    }

    /// A local file to show, and a font, so that terminals have cells to click.
    private func temporaryFile() throws -> URL {
        let savedFont = FontShaper.settings
        FontShaper.settings = { (SessionManager.shared.config, 14) }
        FontShaper.invalidateAll()
        addTeardownBlock {
            FontShaper.settings = savedFont
            FontShaper.invalidateAll()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: file)
        return file
    }

    func testCommandOptionClickPreviewsTheFileUnderThePointer() throws {
        let file = try temporaryFile()
        try withContent(floating: true) { content, window in
            let cards = content.floating
            for pane in [first, card] {
                var previewed: [String] = []
                let points = try show(file.path, in: content, pane: pane) { previewed.append($0.path) }
                try drag(pane, in: content, window: window, modifiers: moveModifiers, start: points.onPath,
                         clickOnly: true)
                XCTAssertEqual(previewed, [file.path], "Pane: \(pane)")
                XCTAssertEqual(content.root.panes, [first, second])
                XCTAssertEqual(content.floating, cards)
                try drag(pane, in: content, window: window, modifiers: moveModifiers, start: points.blank,
                         clickOnly: true)
                XCTAssertEqual(previewed, [file.path], "A click off the path previewed it")
            }
        }
    }

    func testOtherClicksOnAPathDoNotPreviewIt() throws {
        let file = try temporaryFile()
        for flags in [[], .command, .option, [.command, .option, .shift]] as [NSEvent.ModifierFlags] {
            try withContent { content, window in
                var previewed: [String] = []
                let points = try show(file.path, in: content, pane: first) { previewed.append($0.path) }
                try drag(first, in: content, window: window, modifiers: flags, start: points.onPath, clickOnly: true)
                XCTAssertEqual(previewed, [], "Modifiers: \(flags.rawValue)")
            }
        }
    }

    func testDraggingOrEscapeFromAPathDoesNotPreviewIt() throws {
        let file = try temporaryFile()
        for floating in [false, true] {
            for (cancel, clickOnly) in [(false, false), (true, false), (true, true)] {
                try withContent(floating: floating) { content, window in
                    let pane = floating ? card : first
                    var previewed: [String] = []
                    let points = try show(file.path, in: content, pane: pane) { previewed.append($0.path) }
                    try drag(pane, in: content, window: window, modifiers: moveModifiers, start: points.onPath,
                             cancel: cancel, clickOnly: clickOnly)
                    XCTAssertEqual(previewed, [], "Floating: \(floating), Esc: \(cancel), moved: \(!clickOnly)")
                }
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
