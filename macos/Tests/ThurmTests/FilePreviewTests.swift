import AppKit
import QuickLookUI
import XCTest
@testable import Thurm

final class FilePreviewTests: XCTestCase {
    private func reference(_ text: String, at needle: String, link: URL? = nil) -> TerminalFileReference? {
        let range = (text as NSString).range(of: needle)
        return TerminalFileReference.at(text: text, columns: Array(0..<text.utf16.count),
                                        column: range.location, link: link)
    }

    func testPathsAndDiagnosticLocations() {
        for path in ["/tmp/image.png", "./report.pdf", "../assets/icon.png", "~/photo.jpg",
                     "report.pdf", "src/main.swift:12:3", "./LICENSE", ".env", "/tmp/file(1)"] {
            XCTAssertEqual(reference("See \(path)", at: path), .path(path))
        }
        XCTAssertEqual(reference("See (./report.pdf), next", at: "report"), .path("./report.pdf"))
        XCTAssertNil(reference("ordinary output", at: "output"))
        XCTAssertNil(reference("image.png   ", at: "   "))
        XCTAssertEqual(reference("src/main.swift:12:3:", at: "main"), .path("src/main.swift:12:3"))
    }

    func testQuotedAndEscapedSpaces() {
        XCTAssertEqual(reference(#"See "./My Report.pdf" now"#, at: "Report"), .path("./My Report.pdf"))
        XCTAssertEqual(reference("'./My Report.pdf'", at: "Report"), .path("./My Report.pdf"))
        XCTAssertEqual(reference("`./My Report.pdf`", at: "Report"), .path("./My Report.pdf"))
        XCTAssertEqual(reference(#"./My\ Report.pdf"#, at: "Report"), .path("./My Report.pdf"))
        XCTAssertEqual(reference("'./file(1).pdf'", at: "file"), .path("./file(1).pdf"))
    }

    func testCellMapAndHyperlinkPriority() {
        let text = "😀 report.pdf"
        let columns = [0, 0, 2] + Array(3..<13)
        XCTAssertEqual(TerminalFileReference.at(text: text, columns: columns, column: 8, link: nil),
                       .path("report.pdf"))
        XCTAssertNil(TerminalFileReference.at(text: text, columns: [], column: 8, link: nil))
        let web = URL(string: "https://example.com/image.png")!
        XCTAssertNil(reference("image.png", at: "image", link: web))
        let file = URL(string: "file:///tmp/My%20Report.pdf")!
        XCTAssertEqual(reference("click here", at: "here", link: file), .fileURL(file))
    }

    func testResolutionUsesPaneDirectoryAndHome() throws {
        XCTAssertEqual(try TerminalFileReference.path("../image.png").resolve(cwd: "/work/sub", isRemote: false).path,
                       "/work/image.png")
        XCTAssertEqual(try TerminalFileReference.path("image.png").resolve(cwd: "/other", isRemote: false).path,
                       "/other/image.png")
        XCTAssertEqual(try TerminalFileReference.path("~/image.png").resolve(cwd: nil, isRemote: false,
                                                                             home: "/Users/test").path,
                       "/Users/test/image.png")
        XCTAssertEqual(try TerminalFileReference.path("/tmp/image.png").resolve(cwd: nil, isRemote: false).path,
                       "/tmp/image.png")
        for cwd in [nil, "", "relative", "//server/share"] as [String?] {
            XCTAssertThrowsError(try TerminalFileReference.path("image.png").resolve(cwd: cwd, isRemote: false)) {
                XCTAssertEqual($0 as? FilePreviewError, .noDirectory)
            }
        }
    }

    func testLocalFileURLsDecodeOnce() throws {
        for host in ["", "localhost", "test.local"] {
            let ref = TerminalFileReference.fileURL(URL(string: "file://\(host)/tmp/My%20Report%2520.pdf")!)
            XCTAssertEqual(try ref.resolve(cwd: nil, isRemote: false, localHostName: "test.local").path,
                           "/tmp/My Report%20.pdf")
        }
        XCTAssertEqual(try TerminalFileReference.path("/tmp/a%20b.pdf").resolve(cwd: nil, isRemote: false).path,
                       "/tmp/a%20b.pdf")
    }

    func testRemoteReferencesNeverResolveOnThisMac() {
        for ref in [TerminalFileReference.path("/etc/hosts"), .path("~/image.png"),
                    .fileURL(URL(string: "file:///etc/hosts")!)] {
            XCTAssertThrowsError(try ref.resolve(cwd: "/tmp", isRemote: true)) {
                XCTAssertEqual($0 as? FilePreviewError, .remote)
            }
        }
        XCTAssertThrowsError(try TerminalFileReference.fileURL(URL(string: "file://other-host/tmp/a.pdf")!)
            .resolve(cwd: nil, isRemote: false)) { XCTAssertEqual($0 as? FilePreviewError, .remote) }
        for path in ["sftp://host/tmp/a.pdf", "host:/tmp/a.pdf", "user@host:report.pdf"] {
            XCTAssertThrowsError(try TerminalFileReference.path(path).resolve(cwd: "/tmp", isRemote: false)) {
                XCTAssertEqual($0 as? FilePreviewError, .remote)
            }
        }
    }

    func testInvalidReferences() {
        for path in ["~other/image.png", "/tmp/a\0.pdf", "//host/share/image.png"] {
            XCTAssertThrowsError(try TerminalFileReference.path(path).resolve(cwd: "/tmp", isRemote: false))
        }
        for url in ["file:relative.pdf", "file:///tmp/a.pdf?query", "file:///tmp/a.pdf#fragment",
                    "file://user@localhost/tmp/a.pdf"] {
            XCTAssertThrowsError(try TerminalFileReference.fileURL(URL(string: url)!).resolve(cwd: nil, isRemote: false))
        }
    }

    func testHostRelativeSCPPathsRejectLocalNameCollisions() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        for name in ["server:report.pdf", "server:report.pdf:12:3", "server.example:report.pdf"] {
            let file = directory.appendingPathComponent(name)
            try Data("local file".utf8).write(to: file)
            let ref = try XCTUnwrap(reference(name, at: name))
            XCTAssertThrowsError(try ref.localFile(cwd: directory.path, isRemote: false)) {
                XCTAssertEqual($0 as? FilePreviewError, .remote)
            }
            for explicitPath in ["./" + name, file.path] {
                XCTAssertEqual(try TerminalFileReference.path(explicitPath)
                    .localFile(cwd: directory.path, isRemote: false).path, file.path)
            }
        }
        for path in ["server:reports/report.pdf", "server:~/report.pdf", "server:report.pdf:12"] {
            XCTAssertThrowsError(try TerminalFileReference.path(path).resolve(cwd: nil, isRemote: false)) {
                XCTAssertEqual($0 as? FilePreviewError, .remote)
            }
        }
    }

    func testFileURLDiagnosticFallbackKeepsLiteralNamesAndValidatesHost() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("My Report%20.pdf")
        try Data("base file".utf8).write(to: file)
        for suffix in [":42", ":42:3"] {
            let literal = directory.appendingPathComponent(file.lastPathComponent + suffix)
            for host in ["", "localhost", ProcessInfo.processInfo.hostName] {
                var parts = try XCTUnwrap(URLComponents(url: literal, resolvingAgainstBaseURL: false))
                parts.host = host
                let url = try XCTUnwrap(parts.url)
                let ref = try XCTUnwrap(reference("report", at: "report", link: url))
                XCTAssertEqual(try ref.localFile(cwd: nil, isRemote: false).path, file.path)
                try Data("literal file".utf8).write(to: literal)
                XCTAssertEqual(try ref.localFile(cwd: nil, isRemote: false).path, literal.path)
                parts.host = "other-host.invalid"
                let remote = TerminalFileReference.fileURL(try XCTUnwrap(parts.url))
                XCTAssertThrowsError(try remote.localFile(cwd: directory.path, isRemote: false)) {
                    XCTAssertEqual($0 as? FilePreviewError, .remote)
                }
                try fm.removeItem(at: literal)
                XCTAssertThrowsError(try remote.localFile(cwd: directory.path, isRemote: false)) {
                    XCTAssertEqual($0 as? FilePreviewError, .remote)
                }
                parts.host = "localhost"
                parts.query = "query"
                XCTAssertThrowsError(try TerminalFileReference.fileURL(XCTUnwrap(parts.url))
                    .localFile(cwd: nil, isRemote: false)) {
                    XCTAssertEqual($0 as? FilePreviewError, .invalid)
                }
            }
        }
    }

    func testFileValidationAndLiteralSuffix() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.pdf")
        try Data("test".utf8).write(to: file)
        XCTAssertEqual(try TerminalFileReference.path("report.pdf:12:3")
            .localFile(cwd: directory.path, isRemote: false).path, file.path)
        let literal = directory.appendingPathComponent("report.pdf:12:3")
        try Data("literal".utf8).write(to: literal)
        XCTAssertEqual(try TerminalFileReference.path("report.pdf:12:3")
            .localFile(cwd: directory.path, isRemote: false).path, literal.path)
        let symlink = directory.appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertNoThrow(try TerminalFileReference.path(symlink.path).localFile(cwd: nil, isRemote: false))
        XCTAssertThrowsError(try TerminalFileReference.path(directory.path).localFile(cwd: nil, isRemote: false)) {
            XCTAssertEqual($0 as? FilePreviewError, .unsupported)
        }
        try fm.removeItem(at: file)
        XCTAssertThrowsError(try TerminalFileReference.path(symlink.path).localFile(cwd: nil, isRemote: false)) {
            XCTAssertEqual($0 as? FilePreviewError, .missing)
        }
        XCTAssertThrowsError(try TerminalFileReference.path(file.path).localFile(cwd: nil, isRemote: false)) {
            XCTAssertEqual($0 as? FilePreviewError, .missing)
        }
    }

    func testMenuKeepsClickedPaneContext() throws {
        _ = NSApplication.shared
        let pane = PaneKey.local(987654)
        let manager = SessionManager.shared
        let previous = manager.panes[pane]
        defer { manager.panes[pane] = previous }
        manager.panes[pane] = PaneInfo(json: ["id": pane.id, "cwd": "/clicked"])
        let view = TerminalView(pane: pane)
        let menu = view.contextMenu(link: nil, file: .path("report.pdf"))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Quick Look" })
        let request = try XCTUnwrap(item.representedObject as? FilePreviewRequest)
        manager.panes[pane]?.cwd = "/changed"
        XCTAssertEqual(request.cwd, "/clicked")
        XCTAssertFalse(request.isRemote)
        XCTAssertEqual(request.reference, .path("report.pdf"))
        XCTAssertTrue(item.target === view)
        XCTAssertNil(view.contextMenu(link: URL(string: "https://example.com")).items.first { $0.title == "Quick Look" })
        let remote = TerminalView(pane: PaneKey("remote", 987654))
        let remoteMenu = remote.contextMenu(link: nil, file: .path("report.pdf"))
        XCTAssertTrue((remoteMenu.items.first?.representedObject as? FilePreviewRequest)?.isRemote == true)
    }

    func testPreviewPanelOpensChangesFileAndClosesWithView() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(pane: .local(987655))
        window.contentView = view
        defer {
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        guard NSApp.mainWindow === window else {
            throw XCTSkip("This test requires an AppKit session that can make a window main.")
        }
        for name in ["first.txt", "second.txt"] {
            let file = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            let menu = view.contextMenu(link: nil, file: .path(file.path))
            let item = try XCTUnwrap(menu.items.first { $0.title == "Quick Look" })
            _ = view.perform(try XCTUnwrap(item.action), with: item)
            let panel = try XCTUnwrap(QLPreviewPanel.shared())
            XCTAssertTrue(panel.currentController as AnyObject? === view)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.currentPreviewItem?.previewItemURL, file)
            XCTAssertEqual(view.numberOfPreviewItems(in: panel), 1)
            XCTAssertNil(view.previewPanel(panel, previewItemAt: 1))
        }
        view.removeFromSuperview()
        XCTAssertFalse(QLPreviewPanel.shared().isVisible)
    }
}
