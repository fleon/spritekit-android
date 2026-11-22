import Foundation
import PlatformCore
import XCTest

private final class Count: @unchecked Sendable {
    var value = 0
}

final class ObserverBagTests: XCTestCase {
    private let ping = Notification.Name("ObserverBagTests.ping")

    func testObservesUntilRemoved() {
        let center = NotificationCenter()
        let count = Count()
        let bag = ObserverBag(center: center)
        bag.observe(ping) { _ in count.value += 1 }
        bag.observe(ping) { _ in count.value += 10 }
        center.post(name: ping, object: nil)
        XCTAssertEqual(count.value, 11)
        bag.removeAll()
        center.post(name: ping, object: nil)
        XCTAssertEqual(count.value, 11)
    }

    func testRemovesWhenItGoes() {
        let center = NotificationCenter()
        let count = Count()
        var bag: ObserverBag? = ObserverBag(center: center)
        bag?.observe(ping) { _ in count.value += 1 }
        bag?.add([center.addObserver(forName: ping, object: nil, queue: nil) { _ in count.value += 10 }])
        center.post(name: ping, object: nil)
        bag = nil
        center.post(name: ping, object: nil)
        XCTAssertEqual(count.value, 11)
    }

    func testFiltersBySender() {
        let center = NotificationCenter()
        let count = Count()
        let sender = NSObject()
        let bag = ObserverBag(center: center)
        bag.observe(ping, object: sender) { _ in count.value += 1 }
        center.post(name: ping, object: NSObject())
        center.post(name: ping, object: sender)
        XCTAssertEqual(count.value, 1)
        withExtendedLifetime(bag) {}
    }
}
