#if SPRITEKIT_SHIM
import Foundation

/// The Objective-C runtime's associated objects, which Android has no
/// runtime for: values hung on an object by a key, as a protocol extension
/// keeps state on whatever class adopts it.
///
/// Keyed by the object's identity and the key's address. Objective-C lets a
/// value go when its object is deallocated; Swift has no hook for that here,
/// so each entry keeps a weak reference to its object, and an entry whose
/// object has gone is dropped the next time it's looked at, or by a sweep
/// every so many writes (an identity is reused once its object is gone, so
/// a stale entry must never answer for a new object).
enum AssociatedObjects {
    private final class Entry {
        weak var object: AnyObject?
        var values: [UnsafeRawPointer: Any] = [:]
        init(_ object: AnyObject) { self.object = object }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var entries: [ObjectIdentifier: Entry] = [:]
    private nonisolated(unsafe) static var writes = 0
    static let sweepEvery = 256

    // Every value taken off is let go only once the lock is open again: a
    // value's `deinit` may hang or take values itself, which under the lock
    // would deadlock (or, on Darwin, abort on the lock's recursion).

    /// What `object` holds under `key`, if anything.
    static func value(of object: AnyObject, for key: UnsafeRawPointer) -> Any? {
        var released: [Any] = []
        lock.lock()
        let value = live(object, releasing: &released)?.values[key]
        lock.unlock()
        released.removeAll()
        return value
    }

    /// Hangs `value` on `object` under `key`, or takes it off for nil.
    static func set(_ value: Any?, of object: AnyObject, for key: UnsafeRawPointer) {
        var released: [Any] = []
        lock.lock()
        writes += 1
        if writes % sweepEvery == 0 {
            for (id, entry) in entries where entry.object == nil {
                released.append(entry)
                entries[id] = nil
            }
        }
        let id = ObjectIdentifier(object)
        let entry = live(object, releasing: &released) ?? Entry(object)
        if let old = entry.values[key] { released.append(old) }
        entry.values[key] = value
        entries[id] = entry.values.isEmpty ? nil : entry
        lock.unlock()
        released.removeAll()
    }

    /// Takes everything off `object`.
    static func removeAll(of object: AnyObject) {
        var released: [Any] = []
        lock.lock()
        if let entry = entries.removeValue(forKey: ObjectIdentifier(object)) { released.append(entry) }
        lock.unlock()
        released.removeAll()
    }

    /// How many objects hold values, for tests.
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.object != nil }.count
    }

    /// The entry for `object` itself, never one left by an object that had
    /// its identity before it (that one goes into `released`).
    private static func live(_ object: AnyObject, releasing released: inout [Any]) -> Entry? {
        let id = ObjectIdentifier(object)
        guard let entry = entries[id] else { return nil }
        guard entry.object === object else {
            released.append(entry)
            entries[id] = nil
            return nil
        }
        return entry
    }
}

#if !canImport(ObjectiveC)
/// `objc_AssociationPolicy`. Every policy retains here: Swift values are
/// copied on assignment anyway, and a value hung unretained is kept
/// alive here rather than dangling.
public enum objc_AssociationPolicy: UInt, @unchecked Sendable {
    case OBJC_ASSOCIATION_ASSIGN = 0
    case OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1
    case OBJC_ASSOCIATION_COPY_NONATOMIC = 3
    case OBJC_ASSOCIATION_RETAIN = 769
    case OBJC_ASSOCIATION_COPY = 771
}

public func objc_getAssociatedObject(_ object: Any, _ key: UnsafeRawPointer) -> Any? {
    AssociatedObjects.value(of: object as AnyObject, for: key)
}

public func objc_setAssociatedObject(_ object: Any, _ key: UnsafeRawPointer, _ value: Any?, _ policy: objc_AssociationPolicy) {
    AssociatedObjects.set(value, of: object as AnyObject, for: key)
}

public func objc_removeAssociatedObjects(_ object: Any) {
    AssociatedObjects.removeAll(of: object as AnyObject)
}
#endif

#endif
