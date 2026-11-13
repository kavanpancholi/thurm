import AppKit
import XCTest
@testable import Thurm

final class InsertPathTests: XCTestCase {
    func testPathsAreSingleShellWords() throws {
        let paths = ["file", "folder name/", "a'b\"c", "../two words/", "/tmp/a b", "-rf",
                     "~literal", "a=b", "$(touch NEVER)", "a;echo bad", "é😀", "back\\slash", "x!#*?[]{}|&<>`$"]
        var shells = ["/bin/sh", "/bin/bash", "/bin/zsh"]
        if let fish = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map({ String($0) + "/fish" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            shells.append(fish)
        }
        for shell in shells {
            for path in paths {
                let text = try XCTUnwrap(InsertPathPicker.shellText(path))
                XCTAssertFalse(text.contains("\n"))
                XCTAssertFalse(text.contains("\r"))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = shell.hasSuffix("/fish") ? ["--no-config"] : shell.hasSuffix("/zsh") ? ["-f"] : []
                let input = Pipe()
                process.standardInput = input
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                // Send UTF-8 bytes through stdin. Process arguments can normalize Unicode on macOS.
                input.fileHandleForWriting.write(Data(("printf '%s\\0' " + text).utf8))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let expected = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") ? path : "./" + path
                XCTAssertEqual(data, Data((expected + "\0").utf8), "\(shell): \(path)")
            }
        }
    }

    func testControlCharactersCannotReachTheTerminal() {
        for path in ["", "a\nb", "a\rb", "a\u{1b}[201~b", "a\0b", "a\tb", "a\u{7f}b"] {
            XCTAssertNil(InsertPathPicker.shellText(path))
        }
        XCTAssertEqual(InsertPathPicker.shellText("./folder/"), "./folder/ ")
    }

    func testRecentPathsKeepHostAndFolderAndPersistInOrder() throws {
        let suite = "InsertPathTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = PathHistory(defaults: defaults)
        let local = RecentPath(host: localHost, cwd: "/work", path: "a b", isDirectory: false)
        let remote = RecentPath(host: "server", cwd: "/work", path: "a b", isDirectory: true)
        let elsewhere = RecentPath(host: localHost, cwd: "/other", path: "a b", isDirectory: false)
        for entry in [local, remote, elsewhere, local] { history.record(entry) }
        XCTAssertEqual(history.entries, [local, elsewhere, remote])
        XCTAssertEqual(history.paths(host: localHost, cwd: "/work", query: "B"), [local])
        XCTAssertEqual(history.paths(host: "server", cwd: "/work", query: ""), [remote])
        XCTAssertEqual(PathHistory(defaults: defaults).entries, history.entries)
        for i in 0..<60 {
            history.record(RecentPath(host: localHost, cwd: "/work", path: "\(i)", isDirectory: false))
        }
        XCTAssertEqual(history.entries.count, 50)
        XCTAssertEqual(history.entries.first?.path, "59")
    }

    func testPathCommandUsesMenuConventions() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let item = try XCTUnwrap(MainMenu.keyedItem("p", [.command, .option], in: menu))
        XCTAssertEqual(item.identifier, MainMenu.actionIdentifier("insert_path"))
        XCTAssertEqual(item.action, #selector(TerminalView.insertPath(_:)))
    }
}

final class InsertPathPickerTests: XCTestCase {
    private var controller: TerminalWindowController?
    private var palette = CommandPalette()
    private var picker: InsertPathPicker?
    private var replies: [String: (Any?) -> Void] = [:]
    private var requested: XCTestExpectation?
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suite = "InsertPathPickerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        palette.close()
        picker = nil
        controller?.closingWithoutConfirmation = true
        controller?.window?.close()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func open() throws -> TerminalView {
        let pane = PaneKey("remote-test", 42)
        let c = SessionManager.shared.makeController(root: .leaf(pane), focused: pane, zoomed: nil, title: nil, frame: nil)
        controller = c
        let terminal = try XCTUnwrap(c.content.focusedView)
        terminal.setOffline(nil)
        c.window?.makeKeyAndOrderFront(nil)
        picker = InsertPathPicker(history: PathHistory(defaults: defaults), palette: palette) { [weak self] target, query, reply in
            XCTAssertEqual(target, pane)
            self?.replies[query] = reply
            self?.requested?.fulfill()
        }
        requested = expectation(description: "Initial search")
        picker?.show(for: terminal)
        wait(for: [requested!], timeout: 2)
        return terminal
    }

    private func controls() throws -> (NSTextField, NSTableView) {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let all = NSApp.windows.compactMap(\.contentView).flatMap(views)
        let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.delegate === palette })
        let table = try XCTUnwrap(field.window?.contentView.flatMap { views($0).compactMap { $0 as? NSTableView }.first })
        return (field, table)
    }

    private func result(_ paths: [String]) -> Any {
        ["PathMatches": ["cwd": "/remote/work", "truncated": false,
                         "items": paths.map { ["text": $0, "kind": $0.hasSuffix("/") ? "Directory" : "File"] }]]
    }

    func testLateRepliesCannotReplaceNewResultsOrReopenThePicker() throws {
        let terminal = try open()
        let firstReply = try XCTUnwrap(replies[""])
        requested = expectation(description: "Changed search")
        palette.setSearchQuery("folder")
        wait(for: [requested!], timeout: 2)
        let reply = try XCTUnwrap(replies["folder"])
        reply(result(["folder name/"]))
        let (field, table) = try controls()
        XCTAssertEqual(palette.numberOfRows(in: table), 1)
        firstReply(result(["old", "stale"]))
        XCTAssertEqual(palette.numberOfRows(in: table), 1)
        XCTAssertEqual(field.stringValue, "folder")

        requested = expectation(description: "Open selected folder")
        XCTAssertTrue(palette.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        wait(for: [requested!], timeout: 2)
        XCTAssertEqual(field.stringValue, "./folder name/")
        XCTAssertEqual(palette.numberOfRows(in: table), 0)
        let folderReply = try XCTUnwrap(replies["./folder name/"])
        XCTAssertTrue(palette.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        folderReply(result(["late"]))
        XCTAssertFalse(palette.isVisible)
        XCTAssertTrue(PathHistory(defaults: defaults).entries.isEmpty)

        requested = expectation(description: "Reopen")
        picker?.show(for: terminal)
        wait(for: [requested!], timeout: 2)
        folderReply(result(["old session"]))
        XCTAssertEqual(palette.numberOfRows(in: table), 0)
        replies[""]?(result(["new session"]))
        XCTAssertEqual(palette.numberOfRows(in: table), 1)
    }

    func testErrorsAndEmptyResultsCannotBeAccepted() throws {
        _ = try open()
        let (field, table) = try controls()
        replies[""]?(["error": "Update Thurm on this host to use Insert Path."])
        XCTAssertEqual(palette.numberOfRows(in: table), 0)
        XCTAssertTrue(palette.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(palette.isVisible)
        XCTAssertTrue(PathHistory(defaults: defaults).entries.isEmpty)
        replies[""]?(result([]))
        XCTAssertEqual(palette.numberOfRows(in: table), 0)
    }
}
