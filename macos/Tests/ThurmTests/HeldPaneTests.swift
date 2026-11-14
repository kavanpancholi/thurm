import AppKit
import XCTest
@testable import Thurm

final class HeldPaneTests: XCTestCase {
    private let manager = SessionManager.shared
    private let key = PaneKey(localHost, 900_101)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        manager.coreDidReceiveEvent("PaneInfo", payload: ["id": NSNumber(value: key.id), "title": "echo",
                                                          "alive": true], host: localHost)
    }

    override func tearDown() {
        manager.panes[key] = nil
        super.tearDown()
    }

    private var pane: [String: Any] { ["pane": NSNumber(value: key.id)] }

    func testAnExitedPaneStaysUntilItIsClosed() {
        manager.coreDidReceiveEvent("PaneExited", payload: pane.merging(["code": 0]) { $1 }, host: localHost)
        XCTAssertEqual(manager.panes[key]?.alive, false)

        manager.coreDidReceiveEvent("PaneClosed", payload: pane, host: localHost)
        XCTAssertNil(manager.panes[key])
    }
}
