import XCTest
@testable import Thurm

final class TitlebarDoubleClickTests: XCTestCase {
    func testSettingValues() {
        XCTAssertEqual(TitlebarDoubleClick(action: "Maximize", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitlebarDoubleClick(action: "Fill", legacyMinimize: false), .fill)
        XCTAssertEqual(TitlebarDoubleClick(action: "Minimize", legacyMinimize: false), .minimize)
        XCTAssertEqual(TitlebarDoubleClick(action: "None", legacyMinimize: false), .ignore)
    }

    func testUnsetZooms() {
        XCTAssertEqual(TitlebarDoubleClick(action: nil, legacyMinimize: false), .zoom)
        XCTAssertEqual(TitlebarDoubleClick(action: "Unknown", legacyMinimize: false), .zoom)
    }

    func testLegacyMinimizeOnlyWhenActionUnset() {
        XCTAssertEqual(TitlebarDoubleClick(action: nil, legacyMinimize: true), .minimize)
        XCTAssertEqual(TitlebarDoubleClick(action: "Maximize", legacyMinimize: true), .zoom)
        XCTAssertEqual(TitlebarDoubleClick(action: "Unknown", legacyMinimize: true), .zoom)
    }
}
