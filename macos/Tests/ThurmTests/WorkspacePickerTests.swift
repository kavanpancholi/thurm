import AppKit
import XCTest
@testable import Thurm

final class WorkspacePickerTests: XCTestCase {
    private let manager = SessionManager.shared
    private var savedWorkspaces: [Workspace] = []
    private var controller: TerminalWindowController?
    private var picker = WorkspacePicker()

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedWorkspaces = manager.workspaces
    }

    override func tearDown() {
        picker.close()
        controller?.closingWithoutConfirmation = true
        controller?.window?.close()
        controller = nil
        manager.workspaces = savedWorkspaces
        super.tearDown()
    }

    func testFilteringByNameOrRemoteHostPreservesWorkspaceShortcuts() {
        let workspaces = [Workspace(id: 1, name: "crisp-tiger"),
                          Workspace(id: 2, name: "Deploy", host: "devbox"),
                          Workspace(id: 3, name: "Review")]
        let name = WorkspacePicker.matching(workspaces, query: " REv ")
        XCTAssertEqual(name.map { $0.workspace.id }, [3])
        XCTAssertEqual(name.map(\.shortcut), ["⌃⌘3"])
        let host = WorkspacePicker.matching(workspaces, query: "DEVBOX")
        XCTAssertEqual(host.map { $0.workspace.id }, [2])
        XCTAssertEqual(host.map(\.shortcut), ["⌃⌘2"])
        XCTAssertTrue(WorkspacePicker.matching(workspaces, query: "missing").isEmpty)
    }

    func testPickerStaysOnScreenAndBoundsLongLists() {
        // Include a screen to the left of the primary display, both edges, and middle
        // anchors where neither side has room for the full-height picker.
        let screen = NSRect(x: -1440, y: -120, width: 1440, height: 900)
        for anchor in [NSRect(x: -1430, y: 740, width: 100, height: 30),
                       NSRect(x: -30, y: -100, width: 20, height: 30),
                       NSRect(x: -700, y: 310, width: 100, height: 30),
                       NSRect(x: -700, y: 335, width: 100, height: 30)] {
            let frame = WorkspacePicker.frame(anchor: anchor, contentHeight: 1200, screen: screen)
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertLessThanOrEqual(frame.height, 460)
            XCTAssertFalse(frame.intersects(anchor))
            XCTAssertTrue(frame.maxY <= anchor.minY - 6 || frame.minY >= anchor.maxY + 6)
        }
    }

    func testShortPickerPrefersBelowEvenWhenThereIsMoreRoomAbove() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 400, y: 300, width: 100, height: 30)
        let frame = WorkspacePicker.frame(anchor: anchor, contentHeight: 226, screen: screen)
        XCTAssertEqual(frame.height, 226)
        XCTAssertEqual(frame.maxY, anchor.minY - 6)
    }

    private func open() throws -> (NSWindow, NSView, NSWindow, NSTextField) {
        let pane = PaneKey(localHost, 1)
        let c = manager.makeController(root: .leaf(pane), focused: pane, zoomed: nil, title: nil, frame: nil)
        controller = c
        c.workspaceID = 42
        manager.workspaces = [Workspace(id: 42, name: "crisp-tiger")]
        let window = try XCTUnwrap(c.window)
        let anchor = NSButton(frame: NSRect(x: 20, y: 80, width: 120, height: 24))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        picker.toggle(relativeTo: anchor)
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is NSPanel })
        func search(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        let field = try XCTUnwrap(panel.contentView.flatMap { search(in: $0) })
        return (window, anchor, panel, field)
    }

    func testEscapeAndSecondClickDismissAndDetachPanel() throws {
        let (window, anchor, panel, field) = try open()
        XCTAssertTrue(picker.isVisible)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === field)
        XCTAssertTrue(picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(picker.isVisible)
        XCTAssertNil(panel.parent)
        XCTAssertTrue(window.firstResponder === controller?.content.focusedView)

        picker.toggle(relativeTo: anchor)
        XCTAssertTrue(picker.isVisible)
        picker.toggle(relativeTo: anchor)
        XCTAssertFalse(picker.isVisible)
        XCTAssertNil(panel.parent)
    }

    func testReturnOnFilteredCurrentWorkspaceRestoresTerminalFocus() throws {
        let (window, _, panel, field) = try open()
        field.stringValue = "TIGER"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(picker.isVisible)
        XCTAssertEqual(controller?.workspaceID, 42)
        XCTAssertTrue(window.firstResponder === controller?.content.focusedView)
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    func testKeyboardSelectionIsAccessibleAndKeepsFilterFocus() throws {
        let (_, _, panel, field) = try open()
        let content = try XCTUnwrap(panel.contentView)
        let current = try XCTUnwrap(button("crisp-tiger", in: content))
        let newWorkspace = try XCTUnwrap(button("New Workspace", in: content))
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(current.isAccessibilitySelected())
        XCTAssertFalse(newWorkspace.isAccessibilitySelected())

        XCTAssertTrue(picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(current.isAccessibilitySelected())
        XCTAssertTrue(newWorkspace.isAccessibilitySelected())
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(editor.delegate === field)

        XCTAssertTrue(picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(current.isAccessibilitySelected())
        XCTAssertFalse(newWorkspace.isAccessibilitySelected())
    }

    func testOnlyKeyboardSelectionChangesAreAnnounced() throws {
        var announcements: [String] = []
        picker = WorkspacePicker(announceSelection: { announcements.append($0) })
        let (_, _, panel, field) = try open()
        let content = try XCTUnwrap(panel.contentView)
        let current = try XCTUnwrap(button("crisp-tiger", in: content))
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(announcements.isEmpty, "Opening the picker is silent")

        _ = picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        XCTAssertTrue(announcements.isEmpty, "Pressing Up at the first row does not change selection")
        _ = picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(announcements, ["New Workspace"])

        let hover = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        current.mouseEntered(with: hover)
        XCTAssertTrue(current.isAccessibilitySelected())
        XCTAssertEqual(announcements, ["New Workspace"], "Pointer hover is silent")

        field.stringValue = "no matching workspace"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(announcements, ["New Workspace"], "Filtering is silent")
        XCTAssertTrue(try XCTUnwrap(button("New Workspace", in: content)).isAccessibilitySelected())
        _ = picker.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(announcements, ["New Workspace", "Add Remote Host…"])
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(editor.delegate === field)
    }

    func testClosingParentDismissesPicker() throws {
        let (window, _, panel, _) = try open()
        controller?.closingWithoutConfirmation = true
        window.close()
        XCTAssertFalse(picker.isVisible)
        XCTAssertNil(panel.parent)
    }
}
