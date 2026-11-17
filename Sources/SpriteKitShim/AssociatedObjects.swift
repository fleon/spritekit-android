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
public enum AssociatedObjects {
    private final class Entry {
        weak var object: AnyObject?
        var values: [UnsafeRawPointer: Any] = [:]
        init(_ object: AnyObject) { self.object = object }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var entries: [ObjectIdentifier: Entry] = [:]
    private nonisolated(unsafe) static var writes = 0
    static let sweepEvery = 256

    /// What `object` holds under `key`, if anything.
    public static func value(of object: AnyObject, for key: UnsafeRawPointer) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = live(object) else { return nil }
        return entry.values[key]
    }

    /// Hangs `value` on `object` under `key`, or takes it off for nil.
    public static func set(_ value: Any?, of object: AnyObject, for key: UnsafeRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        if writes % sweepEvery == 0 { entries = entries.filter { $0.value.object != nil } }
        let id = ObjectIdentifier(object)
        let entry = live(object) ?? Entry(object)
        entry.values[key] = value
        entries[id] = entry.values.isEmpty ? nil : entry
    }

    /// Takes everything off `object`.
    public static func removeAll(of object: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        entries[ObjectIdentifier(object)] = nil
    }

    /// How many objects hold values, for tests.
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.object != nil }.count
    }

    /// The entry for `object` itself, never one left by an object that had
    /// its identity before it.
    private static func live(_ object: AnyObject) -> Entry? {
        let id = ObjectIdentifier(object)
        guard let entry = entries[id] else { return nil }
        guard entry.object === object else {
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
public struct objc_AssociationPolicy: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let OBJC_ASSOCIATION_ASSIGN = objc_AssociationPolicy(rawValue: 0)
    public static let OBJC_ASSOCIATION_RETAIN_NONATOMIC = objc_AssociationPolicy(rawValue: 1)
    public static let OBJC_ASSOCIATION_COPY_NONATOMIC = objc_AssociationPolicy(rawValue: 3)
    public static let OBJC_ASSOCIATION_RETAIN = objc_AssociationPolicy(rawValue: 769)
    public static let OBJC_ASSOCIATION_COPY = objc_AssociationPolicy(rawValue: 771)
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
