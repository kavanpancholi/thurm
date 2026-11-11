import Metal
import XCTest
@testable import Thurm

final class SnapCardTests: XCTestCase {
    private func key(_ id: UInt64) -> PaneKey { .local(id) }
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func requireMetal() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        _ = try XCTUnwrap(MetalContext.shared, "Metal pipeline initialization failed")
    }

    func testSideEdgesSnapToHalvesAndCornersToQuarters() {
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 5, y: 300), in: area), .left)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 995, y: 300), in: area), .right)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 5, y: 40), in: area), .topLeft)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 995, y: 40), in: area), .topRight)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 5, y: 560), in: area), .bottomLeft)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 995, y: 560), in: area), .bottomRight)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 120, y: 3), in: area), .topLeft)
        XCTAssertEqual(FloatingGeometry.snap(at: CGPoint(x: 880, y: 597), in: area), .bottomRight)
        XCTAssertNil(FloatingGeometry.snap(at: CGPoint(x: 500, y: 3), in: area), "the middle of the top edge")
        XCTAssertNil(FloatingGeometry.snap(at: CGPoint(x: 500, y: 300), in: area))
        XCTAssertNil(FloatingGeometry.snap(at: CGPoint(x: 100, y: 300), in: area))
    }

    func testSnapRectsSplitTheAreaWithAGap() {
        let left = FloatingGeometry.rect(.left, in: area)
        let right = FloatingGeometry.rect(.right, in: area)
        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 496, height: 600))
        XCTAssertEqual(right, CGRect(x: 504, y: 0, width: 496, height: 600))
        XCTAssertEqual(FloatingGeometry.rect(.topLeft, in: area), CGRect(x: 0, y: 0, width: 496, height: 296))
        XCTAssertEqual(FloatingGeometry.rect(.bottomRight, in: area), CGRect(x: 504, y: 304, width: 496, height: 296))
        for zone in FloatingSnap.allCases {
            XCTAssertTrue(area.contains(FloatingGeometry.rect(zone, in: area)), "\(zone) stays in the area")
        }
    }

    func testTabLayoutCodesSnappedCards() throws {
        let card = try JSONDecoder().decode(FloatingPane.self, from: Data(#"{"id":2,"frame":[0.5,0,0.5,1],"snap":"right"}"#.utf8))
        XCTAssertEqual(card.snap, .right)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(card), as: UTF8.self).contains("\"snap\":\"right\""))
        XCTAssertEqual(FloatingCard(card).saved, card)
        let corner = try JSONDecoder().decode(FloatingPane.self, from: Data(#"{"id":2,"frame":[0,0,1,1],"snap":"bottom_left"}"#.utf8))
        XCTAssertEqual(corner.snap, .bottomLeft)
        let newer = try JSONDecoder().decode(FloatingPane.self, from: Data(#"{"id":2,"frame":[0,0,1,1],"snap":"top"}"#.utf8))
        XCTAssertNil(newer.snap, "a snap this app does not know leaves the card where its frame says")
        let plain = FloatingPane(pane: key(2), frame: [0.1, 0.2, 0.5, 0.5])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("snap"))
    }

    func testASnappedCardStaysInItsHalfWhenTheTabResizes() throws {
        try requireMetal()
        let content = TabContentView(root: .leaf(key(1)), focused: key(1), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.1, 0.1, 0.3, 0.3], snap: .right)])
        defer { content.detachAll() }
        for size in [CGSize(width: 1000, height: 600), CGSize(width: 1400, height: 900), CGSize(width: 700, height: 500)] {
            content.frame = CGRect(origin: .zero, size: size)
            content.layoutPanes()
            let half = FloatingGeometry.rect(.right, in: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
            let view = try XCTUnwrap(content.views[key(3)])
            XCTAssertEqual(view.frame.minX, half.minX + 1, accuracy: 0.5, "at \(size)")
            XCTAssertEqual(view.frame.maxX, half.maxX - 1, accuracy: 0.5, "at \(size)")
            XCTAssertEqual(view.frame.maxY, half.maxY - 1, accuracy: 0.5, "at \(size)")
        }
    }

    func testSnappingACardDropsItsZoomAndCells() throws {
        try requireMetal()
        let content = TabContentView(root: .leaf(key(1)), focused: key(3), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.1, 0.1, 0.3, 0.3], zoomed: true,
                                                             cells: CardCells(cols: 40, rows: 10))])
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        defer { content.detachAll() }
        content.snapCard(key(3), to: .bottomLeft)
        let saved = try XCTUnwrap(content.tabLayout(title: nil).floating?.first)
        XCTAssertEqual(saved.snap, .bottomLeft)
        XCTAssertFalse(saved.zoomed)
        XCTAssertNil(saved.cells)
        let quarter = FloatingGeometry.rect(.bottomLeft, in: CGRect(x: 8, y: 8, width: 984, height: 584))
        XCTAssertEqual(saved.frame[0], Double((quarter.minX - 8) / 984), accuracy: 0.001)
        XCTAssertEqual(saved.frame[2], Double(quarter.width / 984), accuracy: 0.001)
    }

    func testPlacingASnappedCardUnsnapsIt() throws {
        try requireMetal()
        let content = TabContentView(root: .leaf(key(1)), focused: key(3), zoomed: nil,
                                     floating: [FloatingPane(pane: key(3), frame: [0.5, 0, 0.5, 1], snap: .right)])
        content.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        content.layoutPanes()
        defer { content.detachAll() }
        XCTAssertTrue(content.placeFloating(key(3), at: .fraction(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))))
        XCTAssertNil(content.tabLayout(title: nil).floating?.first?.snap)
    }
}
