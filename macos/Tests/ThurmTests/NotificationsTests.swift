import XCTest
@testable import Thurm

final class NotificationsTests: XCTestCase {
    private func notice(_ id: String, pane: UInt64, host: String? = nil) -> (identifier: String, userInfo: [AnyHashable: Any]) {
        var info: [AnyHashable: Any] = [Notifications.paneKey: NSNumber(value: pane)]
        if let host { info[Notifications.hostKey] = host }
        return (id, info)
    }

    func testPicksTheNotificationsOfThePanesRead() {
        let delivered = [notice("a", pane: 1, host: localHost), notice("b", pane: 2, host: localHost),
                         notice("c", pane: 1, host: localHost)]
        XCTAssertEqual(Notifications.identifiers(of: delivered, for: [.local(1)]), ["a", "c"])
        XCTAssertEqual(Notifications.identifiers(of: delivered, for: [.local(1), .local(2)]), ["a", "b", "c"])
    }

    /// Pane ids are per daemon: the same number on another host is another pane.
    func testAnotherHostsPaneWithTheSameNumberStays() {
        let delivered = [notice("local", pane: 7, host: localHost), notice("remote", pane: 7, host: "devbox")]
        XCTAssertEqual(Notifications.identifiers(of: delivered, for: [.local(7)]), ["local"])
        XCTAssertEqual(Notifications.identifiers(of: delivered, for: [PaneKey("devbox", 7)]), ["remote"])
    }

    /// A notification posted without a host is this Mac's.
    func testNoHostMeansTheLocalDaemon() {
        XCTAssertEqual(Notifications.identifiers(of: [notice("a", pane: 3)], for: [.local(3)]), ["a"])
    }

    /// Thurm's own notifications (an update, a remote host) carry no pane.
    func testNotificationsWithoutAPaneStay() {
        let own: (identifier: String, userInfo: [AnyHashable: Any]) = ("update", [Notifications.urlKey: "https://example.com"])
        XCTAssertEqual(Notifications.identifiers(of: [own, notice("a", pane: 1)], for: [.local(1)]), ["a"])
        XCTAssertEqual(Notifications.identifiers(of: [own], for: []), [])
    }
}
