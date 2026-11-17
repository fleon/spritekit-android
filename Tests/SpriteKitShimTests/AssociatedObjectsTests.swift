import Foundation
import Testing
@testable import SpriteKitShim

// The Objective-C runtime's associated objects, as `AssociatedObjects`
// keeps them where there is no Objective-C runtime (Android).

private final class Owner {}
private nonisolated(unsafe) var handlersKey: UInt8 = 0
private nonisolated(unsafe) var otherKey: UInt8 = 0

@Suite("Associated objects", .serialized)
struct AssociatedObjectsTests {
    @Test("A value hangs on its object by key, and comes off for nil")
    func hangsAndComesOff() {
        let owner = Owner()
        withUnsafePointer(to: &handlersKey) { key in
            #expect(AssociatedObjects.value(of: owner, for: key) == nil)
            AssociatedObjects.set("handlers", of: owner, for: key)
            #expect(AssociatedObjects.value(of: owner, for: key) as? String == "handlers")
            withUnsafePointer(to: &otherKey) { other in
                #expect(AssociatedObjects.value(of: owner, for: other) == nil)
            }
            #expect(AssociatedObjects.value(of: Owner(), for: key) == nil)
            AssociatedObjects.set(nil, of: owner, for: key)
            #expect(AssociatedObjects.value(of: owner, for: key) == nil)
        }
    }

    @Test("A value is the same instance each time it is read")
    func sameInstance() {
        final class Handlers {}
        let owner = Owner()
        withUnsafePointer(to: &handlersKey) { key in
            AssociatedObjects.set(Handlers(), of: owner, for: key)
            let first = AssociatedObjects.value(of: owner, for: key) as AnyObject
            let second = AssociatedObjects.value(of: owner, for: key) as AnyObject
            #expect(first === second)
        }
    }

    @Test("An object's values go with it, and never answer for a newcomer at its address")
    func goesWithItsObject() {
        withUnsafePointer(to: &handlersKey) { key in
            var leftOver = 0
            for _ in 0..<1000 {
                // Objects made and dropped in a loop reuse addresses.
                let owner = Owner()
                if AssociatedObjects.value(of: owner, for: key) != nil { leftOver += 1 }
                AssociatedObjects.set(1, of: owner, for: key)
            }
            #expect(leftOver == 0)
            #expect(AssociatedObjects.count < AssociatedObjects.sweepEvery + 2)
        }
    }
}
