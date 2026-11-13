import AppKit
import XCTest
@testable import Thurm

final class ActivityAgeTests: XCTestCase {
    private let oldInfo: [String: Any] = ["id": 1, "agent": ["name": "Agent", "status": "Working"]]

    private func pane(_ milliseconds: UInt64?) -> AgentPane {
        var info = PaneInfo(json: oldInfo)!
        info.agent!.updatedAtMs = milliseconds
        return AgentPane(pane: .local(1), info: info, agent: info.agent!, controller: nil, hidden: nil)
    }

    func testOldDaemonsAndClockDifferences() {
        let now = Date(timeIntervalSince1970: 7200)
        XCTAssertNil(PaneInfo(json: oldInfo)?.agent?.updatedAtMs)
        XCTAssertNil(pane(nil).activityAge(now: now))
        XCTAssertNil(pane(0).activityAge(now: now))
        XCTAssertEqual(pane(7_300_000).activityAge(now: now), "updated now")
        XCTAssertEqual(pane(UInt64.max).activityAge(now: now), "updated now")
        XCTAssertEqual(pane(7_199_000).activityAge(now: now), "updated 1s ago")
        XCTAssertEqual(pane(7_180_000).activityAge(now: now), "updated 20s ago")
        XCTAssertEqual(pane(7_080_000).activityAge(now: now), "updated 2m ago")
        XCTAssertEqual(pane(3_600_000).activityAge(now: now), "updated 1h ago")
    }

    func testAgeChangesWithTimeAndAtUnitBoundaries() {
        let agent = pane(1_800_000_000_000)
        for (seconds, text) in [(0, "updated now"), (20, "updated 20s ago"), (59, "updated 59s ago"),
                                (60, "updated 1m ago"), (3599, "updated 59m ago"), (3600, "updated 1h ago"),
                                (86399, "updated 23h ago"), (86400, "updated 1d ago")] {
            XCTAssertEqual(agent.activityAge(now: Date(timeIntervalSince1970: 1_800_000_000 + Double(seconds))), text)
        }
    }

    func testExtendedSnapshotUsesDaemonTimeForEachHost() {
        let json: [String: Any] = ["info": oldInfo, "updated_at_ms": UInt64(1_800_000_000_123)]
        let info = PaneInfo(json: json, host: "remote")!
        XCTAssertEqual(info.agent?.updatedAtMs, 1_800_000_000_123)
        XCTAssertEqual(info.host, "remote")
        XCTAssertEqual(info.id, 1)
        XCTAssertEqual(info.agent?.status, .working)
        XCTAssertNil(PaneInfo(json: ["info": oldInfo, "updated_at_ms": NSNull()])?.agent?.updatedAtMs)
        for invalid in [-1, 0, 1.5, true, "123"] as [Any] {
            XCTAssertNil(PaneInfo(json: ["info": oldInfo, "updated_at_ms": invalid])?.agent?.updatedAtMs)
        }
    }

    func testRowReuseClearsAgeAndKeepsShortcutBehavior() {
        _ = NSApplication.shared
        let row = TabRowView()
        let agent = SidebarTab(controller: nil, title: "Task", subtitle: "Working", status: .working,
                               shortcut: nil, trailingDetail: "updated 20s ago", selected: false)
        row.configure(agent)
        XCTAssertEqual(row.shownShortcut, "updated 20s ago")
        var old = agent
        old.trailingDetail = nil
        XCTAssertNotEqual(agent, old)
        row.configure(old)
        XCTAssertEqual(row.shownShortcut, "")
    }

    func testPickerRefreshKeepsSelectionAndStopsWhenClosed() throws {
        _ = NSApplication.shared
        let picker = CommandPalette()
        var updates = 0
        picker.show(items: [
            .init(title: "Task", detail: "Working", liveShortcut: { now in
                updates += 1
                return self.pane(1_800_000_000_000).activityAge(now: now) ?? ""
            }, action: {}),
            .init(title: "Other", detail: "", action: {}),
        ], over: nil, initialRow: 1)
        defer { picker.close() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0.contentView != nil })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(panel.contentView))
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        panel.contentView?.layoutSubtreeIfNeeded()
        _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        picker.refreshLiveShortcuts(now: Date(timeIntervalSince1970: 1_800_000_020))
        XCTAssertEqual(table.selectedRow, 1)
        let labels = descendants(try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true)))
            .compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "updated 20s ago" })
        let beforeTick = updates
        let tick = expectation(for: NSPredicate { _, _ in updates > beforeTick }, evaluatedWith: nil)
        wait(for: [tick], timeout: 3)
        XCTAssertEqual(table.selectedRow, 1)
        picker.close()
        let before = updates
        picker.refreshLiveShortcuts()
        XCTAssertEqual(updates, before)
    }
}
