import AppKit
import XCTest
@testable import Thurm

final class ActivityGroupsTests: XCTestCase {
    private func agents(_ statuses: [AgentStatus]) -> [AgentBox] {
        statuses.enumerated().map { index, status in
            AgentBox(pane: .local(UInt64(index + 1)), hiddenWorkspace: nil,
                     row: SidebarTab(controller: nil, title: "Agent", status: status, selected: false))
        }
    }

    func testPriorityGroupsKeepPaneOrderAndSkipEmptyGroups() {
        let statuses: [AgentStatus] = [.working, .done, .needsInput, .working, .error]
        let rows = AgentsPanel.grouped(agents(statuses))
        XCTAssertEqual(rows.compactMap(\.heading), ["Needs input", "Failed", "Done", "Working"])
        XCTAssertEqual(rows.compactMap(\.pane), [3, 5, 2, 1, 4].map { PaneKey.local(UInt64($0)) })
        XCTAssertTrue(AgentsPanel.grouped([]).isEmpty)
    }

    func testStatusChangesKeepTheOrderWithinEveryGroup() {
        let statuses: [AgentStatus] = [.working, .error, .done, .needsInput,
                                       .working, .error, .done, .needsInput]
        let rows = AgentsPanel.grouped(agents(statuses))
        XCTAssertEqual(rows.compactMap(\.pane), [4, 8, 2, 6, 3, 7, 1, 5].map { .local(UInt64($0)) })
        var changed = statuses
        changed[0] = .needsInput
        changed[3] = .working
        let next = AgentsPanel.grouped(agents(changed))
        XCTAssertEqual(next.compactMap(\.pane), [1, 8, 2, 6, 3, 7, 4, 5].map { .local(UInt64($0)) })
    }

    func testGroupingPreservesPaneDataAndLeavesIdleAgentsLast() {
        let input = agents([.idle, .working, .idle])
        let remote = AgentBox(pane: PaneKey("remote", 1), hiddenWorkspace: 9,
                              row: SidebarTab(controller: nil, title: "Remote", subtitle: "Project",
                                              status: .needsInput, selected: true))
        let rows = AgentsPanel.grouped(input + [remote])
        XCTAssertEqual(rows.compactMap(\.heading), ["Needs input", "Working", "Idle"])
        XCTAssertTrue(rows[1] === remote)
        XCTAssertEqual(rows[1].hiddenWorkspace, 9)
        XCTAssertTrue(rows[1].row.selected)
        XCTAssertEqual(rows[1].row.subtitle, "Project")
        XCTAssertTrue(rows[5] === input[0])
        XCTAssertTrue(rows[6] === input[2])
        XCTAssertEqual(input.compactMap(\.pane), [1, 2, 3].map { .local(UInt64($0)) })
    }

    func testVisibleLimitCountsAgentsAndIncludesTheirHeadings() {
        let rows = AgentsPanel.grouped(agents([.needsInput, .done, .working, .working]))
        XCTAssertEqual(AgentsPanel.visibleRowCount(rows, limit: 0), 0)
        XCTAssertEqual(AgentsPanel.visibleRowCount(rows, limit: 1), 2)
        XCTAssertEqual(AgentsPanel.visibleRowCount(rows, limit: 2), 4)
        XCTAssertEqual(AgentsPanel.visibleRowCount(rows, limit: 3), 6)
        XCTAssertEqual(AgentsPanel.visibleRowCount(rows, limit: 10), 7)
        XCTAssertEqual(AgentsPanel.visibleRowCount([], limit: 5), 0)
        XCTAssertEqual(AgentsPanel.agentLimit(rows, available: 63), 0)
        XCTAssertEqual(AgentsPanel.agentLimit(rows, available: 64), 1)
        XCTAssertEqual(AgentsPanel.agentLimit(rows, available: 191), 2)
        XCTAssertEqual(AgentsPanel.agentLimit(rows, available: 192), 3)
        XCTAssertEqual(AgentsPanel.agentLimit(rows, available: 232), 4)
    }
}

final class ActivityGroupsViewTests: XCTestCase {
    private let manager = SessionManager.shared
    private var savedConfig = AppConfig()
    private var savedWorkspaces: [Workspace] = []
    private var savedPanes: [PaneKey: PaneInfo] = [:]
    private var controllers: [TerminalWindowController] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedConfig = manager.config
        savedWorkspaces = manager.workspaces
        savedPanes = manager.panes
        manager.workspaces = []
        manager.panes = [:]
        manager.config.sidebarAgents = true
        manager.config.sidebarAllWorkspaces = true
        manager.config.sidebarAgentRows = 2
    }

    override func tearDown() {
        for controller in controllers {
            controller.closingWithoutConfirmation = true
            controller.window?.close()
        }
        controllers = []
        manager.config = savedConfig
        manager.workspaces = savedWorkspaces
        manager.panes = savedPanes
        Remotes.shared.pendingCloses = [:]
        super.tearDown()
    }

    private func setStatus(_ id: UInt64, _ status: AgentStatus) {
        manager.panes[.local(id)] = PaneInfo(json: ["id": id, "agent": ["name": "Codex", "status": status.rawValue]])!
    }

    func testHeadingsCannotBeSelectedAndRowsResizeAfterStatusChanges() throws {
        let workspace = manager.makeWorkspace()
        workspace.hiddenTabs = [1, 2].map {
            TabLayout(title: nil, root: .pane(.local($0)), focused: $0, zoomed: nil)
        }
        setStatus(1, .working)
        setStatus(2, .done)
        let panel = AgentsPanel()
        panel.reload()
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertFalse(table.floatsGroupRows)
        XCTAssertTrue(panel.tableView(table, isGroupRow: 0))
        XCTAssertFalse(panel.tableView(table, shouldSelectRow: 0))
        XCTAssertTrue(panel.tableView(table, shouldSelectRow: 1))
        XCTAssertEqual(table.rect(ofRow: 0).height, 24)
        XCTAssertEqual(table.rect(ofRow: 1).height, 40)
        let heading = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
        XCTAssertEqual(heading?.stringValue, "Done")

        setStatus(2, .working)
        panel.reload()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertFalse(panel.tableView(table, isGroupRow: 2))
        XCTAssertEqual(table.rect(ofRow: 2).height, 40)
        XCTAssertEqual((table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue, "Working")
        setStatus(1, .error)
        setStatus(2, .error)
        panel.reload()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual((table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue, "Failed")
        setStatus(1, .needsInput)
        panel.reload()
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertTrue(panel.tableView(table, isGroupRow: 2))
        XCTAssertEqual(table.rect(ofRow: 2).height, 24)
        XCTAssertEqual(workspace.hiddenTabs.flatMap(\.panes), [.local(1), .local(2)])
    }

    func testActivityPriorityDoesNotChangeOrdinaryTabsOrShortcuts() throws {
        let workspace = manager.makeWorkspace()
        for id: UInt64 in [1, 2, 3] {
            let controller = manager.makeController(root: .leaf(.local(id)), focused: .local(id), zoomed: nil,
                                                     title: nil, frame: nil)
            controller.workspaceID = workspace.id
            if let previous = controllers.last { manager.attachAsTab(controller, to: previous) }
            controllers.append(controller)
        }
        let first = try XCTUnwrap(controllers.first)
        let original = first.orderedTabs
        setStatus(1, .working)
        setStatus(2, .needsInput)
        setStatus(3, .error)
        let panel = AgentsPanel()
        panel.controller = first
        panel.reload()
        XCTAssertEqual(first.orderedTabs, original)
        XCTAssertEqual(first.window?.tabGroup?.windows, original)
        XCTAssertEqual(manager.agentPanes(first: first).map(\.pane), [.local(1), .local(2), .local(3)])

        setStatus(1, .done)
        setStatus(2, .working)
        setStatus(3, .needsInput)
        panel.reload()
        for sidebar in [true, false] {
            manager.config.sidebarTabs = sidebar
            XCTAssertEqual(first.orderedTabs, original)
        }
        XCTAssertEqual(original.indices.map { tabShortcut(index: $0, count: original.count) }, [1, 2, 3])
    }
}
