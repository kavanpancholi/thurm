import AppKit

struct TabHistory {
    static let limit = 50

    private(set) var entries: [[PaneKey]] = []
    private(set) var cursor = -1

    static func sameTab(_ a: [PaneKey], _ b: [PaneKey]) -> Bool {
        !Set(a).isDisjoint(with: b)
    }

    mutating func visit(_ panes: [PaneKey]) {
        guard !panes.isEmpty else { return }
        if entries.indices.contains(cursor), Self.sameTab(entries[cursor], panes) {
            entries[cursor] = panes
            return
        }
        entries.removeSubrange((cursor + 1)...)
        entries.append(panes)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        cursor = entries.count - 1
    }

    mutating func back(isOpen: ([PaneKey]) -> Bool) -> [PaneKey]? {
        let currentOpen = prune(isOpen)
        return move(to: currentOpen ? cursor - 1 : cursor)
    }

    mutating func forward(isOpen: ([PaneKey]) -> Bool) -> [PaneKey]? {
        prune(isOpen)
        return move(to: cursor + 1)
    }

    private mutating func move(to index: Int) -> [PaneKey]? {
        guard entries.indices.contains(index) else { return nil }
        cursor = index
        return entries[index]
    }

    @discardableResult
    private mutating func prune(_ isOpen: ([PaneKey]) -> Bool) -> Bool {
        var kept: [[PaneKey]] = []
        var keptCursor = -1
        var currentOpen = false
        for (i, entry) in entries.enumerated() {
            let open = isOpen(entry)
            if open {
                if let last = kept.last, Self.sameTab(last, entry) {
                    kept[kept.count - 1] = entry
                } else {
                    kept.append(entry)
                }
            }
            if i == cursor {
                keptCursor = kept.count - 1
                currentOpen = open
            }
        }
        entries = kept
        cursor = keptCursor
        return currentOpen
    }
}

extension SessionManager {
    enum TabTarget {
        case shown(TerminalWindowController)
        case hidden(HiddenTab)
    }

    func isHistoryTab(_ c: TerminalWindowController) -> Bool {
        !c.isClosed && !c.isQuick && c.wall == nil
    }

    func recordTabVisit(_ c: TerminalWindowController) {
        guard isHistoryTab(c) else { return }
        tabHistory.visit(c.content.paneIds)
    }

    func tabTarget(_ panes: [PaneKey]) -> TabTarget? {
        for pane in panes {
            if let c = controller(for: pane) { return isHistoryTab(c) ? .shown(c) : nil }
        }
        for ws in workspaces {
            if let i = ws.hiddenTabs.firstIndex(where: { TabHistory.sameTab($0.panes, panes) }) {
                return ws.hiddenTabs[i].wall == nil ? .hidden(HiddenTab(workspace: ws.id, index: i)) : nil
            }
        }
        return nil
    }

    func goBackInTabHistory() {
        show(tabHistory.back { tabTarget($0) != nil })
    }

    func goForwardInTabHistory() {
        show(tabHistory.forward { tabTarget($0) != nil })
    }

    private func show(_ panes: [PaneKey]?) {
        guard let target = panes.flatMap(tabTarget) else {
            NSSound.beep()
            return
        }
        switch target {
        case .shown(let c):
            c.window?.makeKeyAndOrderFront(nil)
        case .hidden(let tab):
            showHiddenTab(tab, from: currentRegularController)
        }
    }
}
