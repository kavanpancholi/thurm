import AppKit
import XCTest
@testable import Thurm

final class CommandPaletteTests: XCTestCase {
    private var palette = CommandPalette()

    override func tearDown() {
        palette.close()
        super.tearDown()
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func open(_ items: [CommandPalette.Item]) throws -> (NSPanel, NSTextField, NSTableView) {
        _ = NSApplication.shared
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        palette.show(items: items, over: nil)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0 is NSPanel && !previous.contains(ObjectIdentifier($0))
        } as? NSPanel)
        let content = try XCTUnwrap(panel.contentView)
        return (panel, try XCTUnwrap(descendant(NSTextField.self, in: content)),
                try XCTUnwrap(descendant(NSTableView.self, in: content)))
    }

    private func search(_ text: String, field: NSTextField) {
        field.stringValue = text
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testMetadataSearchAndLegacyTitleOnlySearch() throws {
        var selected = ""
        let (panel, field, table) = try open([
            CommandPalette.Item(title: "Repair login", detail: "billing on devbox",
                                searchText: "Repair login billing devbox") { selected = "agent" },
            CommandPalette.Item(title: "Theme", detail: "billing on devbox") { selected = "theme" },
        ])
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        for query in [" BILLING ", "devbox", "rplgn"] {
            search(query, field: field)
            XCTAssertEqual(table.numberOfRows, 1)
            XCTAssertEqual(table.selectedRow, 0)
        }
        XCTAssertTrue(palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(selected, "agent")
        XCTAssertFalse(palette.isVisible)
    }

    func testKeyboardNavigationFilteringAndEmptyResults() throws {
        var selected = ""
        let (panel, field, table) = try open([
            CommandPalette.Item(title: "First", detail: "") { selected = "first" },
            CommandPalette.Item(title: "Second", detail: "") { selected = "second" },
        ])
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(table.selectedRow, 1)
        _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(panel.firstResponder === editor)
        _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(table.selectedRow, 0)

        search("no matches", field: field)
        XCTAssertEqual(table.numberOfRows, 0)
        _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(selected, "")
        XCTAssertTrue(palette.isVisible)
        search("Second", field: field)
        XCTAssertEqual(table.selectedRow, 0)
        _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(selected, "second")
    }

    func testEscapeCancelsWithoutRunningAnAction() throws {
        var ran = false
        let (panel, field, _) = try open([CommandPalette.Item(title: "Task", detail: "") { ran = true }])
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(palette.isVisible)
        XCTAssertFalse(ran)
    }
}
