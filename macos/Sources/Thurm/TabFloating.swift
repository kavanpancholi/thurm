import AppKit

typealias TabGap = (tab: TerminalWindowController, after: Bool)

extension SessionManager {
    func floatSources(into c: TerminalWindowController) -> [TerminalWindowController] {
        group(of: c).filter { canFloat($0, into: c) }
    }

    func canFloat(_ src: TerminalWindowController, into c: TerminalWindowController) -> Bool {
        src !== c && canMoveCards(src) && canMoveCards(c) && src.content.root.panes.count == 1
            && src.content.host == c.content.host && group(of: c).contains { $0 === src }
    }

    func canMoveCards(_ c: TerminalWindowController) -> Bool {
        !c.isClosed && !c.isQuick && c.wall == nil && c.handoffID == nil && !isWallOrigin(c)
    }

    func floatTab(_ src: TerminalWindowController, into c: TerminalWindowController, at point: CGPoint? = nil) {
        guard canFloat(src, into: c), let pane = src.content.root.panes.first else { return }
        let frame = point.map { c.content.centeredCardFrame(at: $0) }
            ?? FloatingGeometry.defaultFraction(index: c.content.floating.count)
        let cards = src.content.floating.map(\.saved) + [FloatingCard(pane: pane, frame: frame).saved]
        for card in cards { src.content.remove(pane: card.pane) }
        c.content.addFloating(cards, hidden: false)
        src.closingWithoutConfirmation = true
        src.window?.close()
        c.window?.makeKeyAndOrderFront(nil)
        c.content.focus(pane)
        c.updateTitle()
        focusChanged()
        scheduleLayoutSave()
    }

    func moveCardToNewTab(_ pane: PaneKey, from c: TerminalWindowController, next: TabGap? = nil) {
        guard canMoveCards(c), c.content.isFloating(pane) else { return }
        c.content.remove(pane: pane)
        c.updateTitle()
        newTab(from: next?.tab ?? c, pane: pane, ordered: next?.after == false ? .below : .above)
        controller(for: pane)?.content.focus(pane)
        focusChanged()
    }
}
