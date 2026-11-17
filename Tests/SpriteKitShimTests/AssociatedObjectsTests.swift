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

#if canImport(ObjectiveC)
import ObjectiveC
#endif

private nonisolated(unsafe) var reentryKey: UInt8 = 0

/// Hangs a value on another object as it goes, as a `deinit` may.
private final class Reentrant {
    let other: Owner
    init(_ other: Owner) { self.other = other }
    deinit {
        withUnsafePointer(to: &reentryKey) { AssociatedObjects.set("from deinit", of: other, for: $0) }
    }
}

@Suite("Associated objects: as Objective-C's", .serialized)
struct AssociatedObjectsParityTests {
    @Test("A value whose deinit hangs another value is let go outside the lock")
    func reentrantRelease() {
        let owner = Owner(), other = Owner()
        withUnsafePointer(to: &handlersKey) { key in
            AssociatedObjects.set(Reentrant(other), of: owner, for: key)
            // Replacing it releases it, which re-enters.
            AssociatedObjects.set(nil, of: owner, for: key)
        }
        withUnsafePointer(to: &reentryKey) { key in
            #expect(AssociatedObjects.value(of: other, for: key) as? String == "from deinit")
        }
    }

    #if canImport(ObjectiveC)
    @Test("Hanging, replacing, taking off and removing all answer as the Objective-C runtime's do")
    func matchesObjectiveC() {
        let ours = Owner(), theirs = Owner()
        func both(_ step: (AnyObject) -> Void) { step(ours); step(theirs) }
        func read(_ key: UnsafeRawPointer) -> (String?, String?) {
            (AssociatedObjects.value(of: ours, for: key) as? String, objc_getAssociatedObject(theirs, key) as? String)
        }
        withUnsafePointer(to: &handlersKey) { a in
            withUnsafePointer(to: &otherKey) { b in
                AssociatedObjects.set("one", of: ours, for: a); objc_setAssociatedObject(theirs, a, "one", .OBJC_ASSOCIATION_RETAIN)
                #expect(read(a).0 == read(a).1)
                AssociatedObjects.set("two", of: ours, for: a); objc_setAssociatedObject(theirs, a, "two", .OBJC_ASSOCIATION_RETAIN)
                AssociatedObjects.set("b", of: ours, for: b); objc_setAssociatedObject(theirs, b, "b", .OBJC_ASSOCIATION_RETAIN)
                #expect(read(a).0 == read(a).1 && read(a).0 == "two")
                #expect(read(b).0 == read(b).1)
                AssociatedObjects.set(nil, of: ours, for: a); objc_setAssociatedObject(theirs, a, nil, .OBJC_ASSOCIATION_RETAIN)
                #expect(read(a).0 == nil && read(a).1 == nil)
                #expect(read(b).0 == "b" && read(b).1 == "b")
                AssociatedObjects.removeAll(of: ours); objc_removeAssociatedObjects(theirs)
                #expect(read(b).0 == nil && read(b).1 == nil)
            }
        }
        _ = both
    }

    @Test("The policy's raw values are the runtime's")
    func policyValues() {
        #expect(objc_AssociationPolicy.OBJC_ASSOCIATION_ASSIGN.rawValue == 0)
        #expect(objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC.rawValue == 1)
        #expect(objc_AssociationPolicy.OBJC_ASSOCIATION_COPY_NONATOMIC.rawValue == 3)
        #expect(objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN.rawValue == 769)
        #expect(objc_AssociationPolicy.OBJC_ASSOCIATION_COPY.rawValue == 771)
    }
    #endif
}

@Suite("UIScreen.main")
@MainActor
struct ScreenMainTests {
    @Test("Not optional: the screen last made, as UIKit's one screen")
    func main() {
        let screen = UIScreen(bounds: CGRect(x: 0, y: 0, width: 400, height: 800), nativeScale: 2.625)
        let main: UIScreen = UIScreen.main
        #expect(main === screen)
        #expect(UIScreen.main.scale == 2.625)
    }
}
