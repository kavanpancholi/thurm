import Metal
import XCTest
@testable import Thurm

final class PluginViewsTests: XCTestCase {
    private func key(_ id: UInt64) -> PaneKey { .local(id) }

    private func requireMetal() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        _ = try XCTUnwrap(MetalContext.shared, "Metal pipeline initialization failed")
    }

    override func tearDown() {
        PluginViews.shared.apply([])
        super.tearDown()
    }

    private let json: Any = [[
        "owner": "plugin:usage", "id": "claude", "slot": "window.bottom_trailing",
        "view": [
            "type": "ring", "value": 0.4, "color": "#ff9f0a", "later": true,
            "children": [["type": "icon", "symbol": "sparkle"]],
            "action": ["name": "usage.refresh", "args": ["tool": "claude"]],
            "popover": ["type": "column", "children": [["type": "text", "text": "5-hour limit"]]],
        ],
    ]]

    func testViewsDecodeAsTheDaemonSendsThem() throws {
        let views = PluginViews.decode(json)
        let view = try XCTUnwrap(views.first)
        XCTAssertEqual(view.key, "plugin:usage/claude")
        XCTAssertEqual(view.view.type, "ring")
        XCTAssertEqual(view.view.value, 0.4)
        XCTAssertEqual(view.view.children.first?.symbol, "sparkle")
        XCTAssertEqual(view.view.action?.name, "usage.refresh")
        XCTAssertEqual(view.view.action?.args.flatMap { JSON.decode($0) as? [String: String] }, ["tool": "claude"])
        XCTAssertEqual(view.view.popover?.node.children.first?.text, "5-hour limit")
        XCTAssertNotNil(PluginNodeView.color("#ff9f0a"))
        XCTAssertNil(PluginNodeView.color("#nope"))
        XCTAssertEqual(PluginViews.decode(["not": "a list"]), [])
    }

    func testMountedViewsShowInTheirSlotAboveTheMinimizedCards() throws {
        try requireMetal()
        let root = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(key(1)), second: .leaf(key(2)))
        let content = TabContentView(root: root, focused: key(1), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.2, 0.2, 0.5, 0.5],
                                                             minimized: true)])
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        content.layoutSubtreeIfNeeded()
        let dock = try XCTUnwrap(content.pluginSlots.first { $0.slot == "window.bottom_trailing" })
        XCTAssertTrue(dock.isHidden, "no views, no slot")
        let barAlone = content.minimizedBar.frame

        PluginViews.shared.apply(PluginViews.decode(json))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        content.layoutPanes()
        XCTAssertFalse(dock.isHidden)
        XCTAssertGreaterThan(dock.frame.width, 0)
        XCTAssertEqual(dock.frame.maxX, content.paneArea.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(dock.frame.maxY, content.paneArea.maxY - 10, accuracy: 0.5)
        XCTAssertLessThan(content.minimizedBar.frame.maxY, dock.frame.minY + 0.5, "the chips move up over it")
        XCTAssertLessThan(content.minimizedBar.frame.minY, barAlone.minY)
        XCTAssertTrue(content.pluginSlots.filter { $0.slot != "window.bottom_trailing" }.allSatisfy(\.isHidden))

        PluginViews.shared.apply([])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        content.layoutPanes()
        XCTAssertTrue(dock.isHidden)
    }
}
