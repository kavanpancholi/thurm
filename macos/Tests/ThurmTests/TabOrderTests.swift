import AppKit
import XCTest
@testable import Thurm

final class TabOrderTests: XCTestCase {
    private let manager = SessionManager.shared
    private var savedWorkspaces: [Workspace] = []

    override func setUp() {
        super.setUp()
        savedWorkspaces = manager.workspaces
        manager.workspaces = []
    }

    override func tearDown() {
        for c in manager.liveControllers {
            c.closingWithoutConfirmation = true
            c.window?.close()
        }
        manager.workspaces = savedWorkspaces
        Remotes.shared.pendingCloses = [:]
        super.tearDown()
    }

    private func pane(_ id: UInt64) -> PaneKey { .local(id) }

    private func tab(_ id: UInt64, workspace: Workspace) -> TerminalWindowController {
        let c = manager.makeController(root: .leaf(pane(id)), focused: pane(id), zoomed: nil,
                                       title: nil, frame: nil)
        c.workspaceID = workspace.id
        return c
    }

    private func order(_ c: TerminalWindowController) -> [UInt64] {
        manager.group(of: c).map { $0.content.paneIds[0].id }
    }

    func testBackgroundTabsKeepCreationOrderAndSelection() {
        let first = tab(1, workspace: manager.makeWorkspace())
        let second = tab(2, workspace: manager.workspace(first.workspaceID)!)
        manager.attachAsTab(second, to: first)
        first.window?.tabGroup?.selectedWindow = second.window

        for id: UInt64 in [3, 4, 5] {
            manager.newTab(from: first, pane: pane(id), background: true)
        }

        XCTAssertEqual(order(first), [1, 2, 3, 4, 5])
        XCTAssertTrue(first.window?.tabGroup?.selectedWindow === second.window)
    }

    func testFirstBackgroundTabKeepsItsSourceSelected() {
        let first = tab(1, workspace: manager.makeWorkspace())
        manager.newTab(from: first, pane: pane(2), background: true)
        XCTAssertEqual(order(first), [1, 2])
        XCTAssertTrue(first.window?.tabGroup?.selectedWindow === first.window)
    }

    func testCommandTabsUseTheSourceWorkspace() {
        let source = tab(1, workspace: manager.makeWorkspace())
        let other = tab(9, workspace: manager.makeWorkspace())
        manager.controllerBecameKey(other)

        for id: UInt64 in [2, 3, 4] {
            manager.coreDidReceiveEvent("Ui", payload: ["Open": [
                "pane": id, "target": UInt64(1), "background": true, "new_window": false
            ]], host: localHost)
        }

        XCTAssertEqual(order(source), [1, 2, 3, 4])
        XCTAssertEqual(order(other), [9])
        XCTAssertTrue(source.window?.tabGroup?.selectedWindow === source.window)
    }

    func testCommandTabsStayInAHiddenSourceWorkspace() {
        let hidden = manager.makeWorkspace()
        hidden.hiddenTabs = [TabLayout(title: nil, root: .pane(pane(1)), focused: 1, zoomed: nil)]
        let shown = tab(9, workspace: manager.makeWorkspace())
        manager.controllerBecameKey(shown)

        manager.newCommandTab(pane(2), target: pane(1), background: true)
        manager.newCommandTab(pane(3), target: pane(1), background: true)

        XCTAssertEqual(hidden.hiddenTabs.flatMap(\.panes), [pane(1), pane(2), pane(3)])
        XCTAssertEqual(hidden.hiddenSelectedTab, 0)
        XCTAssertFalse(manager.isShown(hidden))
        XCTAssertEqual(order(shown), [9])
    }

    func testForegroundCommandTabsKeepCreationOrder() {
        let source = tab(1, workspace: manager.makeWorkspace())
        for id: UInt64 in [2, 3, 4] {
            manager.newCommandTab(pane(id), target: pane(1), background: false)
        }
        XCTAssertEqual(order(source), [1, 2, 3, 4])
        XCTAssertTrue(source.window?.tabGroup?.selectedWindow === manager.controller(for: pane(4))?.window)
    }

    func testForegroundCommandRevealsItsSourceWorkspace() throws {
        let hidden = manager.makeWorkspace()
        hidden.hiddenTabs = [TabLayout(title: nil, root: .pane(pane(1)), focused: 1, zoomed: nil)]
        let shown = tab(9, workspace: manager.makeWorkspace())
        manager.controllerBecameKey(shown)

        manager.newCommandTab(pane(2), target: pane(1), background: false)

        let selected = try XCTUnwrap(manager.controller(for: pane(2)))
        XCTAssertEqual(selected.workspaceID, hidden.id)
        XCTAssertEqual(order(selected), [1, 2])
        XCTAssertTrue(selected.window?.tabGroup?.selectedWindow === selected.window)
    }

    func testManualTabsStillOpenNextToTheirSource() {
        let first = tab(1, workspace: manager.makeWorkspace())
        manager.newTab(from: first, pane: pane(2))
        manager.newTab(from: first, pane: pane(3))
        XCTAssertEqual(order(first), [1, 3, 2])
    }

    func testOpeningAWindowPreservesHiddenTabOrder() throws {
        let ws = manager.makeWorkspace()
        ws.hiddenTabs = [1, 2, 3].map {
            TabLayout(title: nil, root: .pane(pane($0)), focused: $0, zoomed: nil)
        }

        manager.newTab(from: nil, pane: pane(4))

        let selected = try XCTUnwrap(manager.controller(for: pane(4)))
        XCTAssertEqual(order(selected), [4, 1, 2, 3])
        XCTAssertTrue(ws.hiddenTabs.isEmpty)
    }
}
