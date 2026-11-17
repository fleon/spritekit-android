#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// Foundation's weak set, which corelibs Foundation leaves out.
/// A weak set of shaders, say, forgets a shader that goes away. Only the
/// weak flavour, and only the common calls.
public final class NSHashTable<ObjectType: AnyObject>: @unchecked Sendable {
    private struct Weak { weak var object: ObjectType? }
    private var entries: [ObjectIdentifier: Weak] = [:]
    private let lock = NSLock()

    private init() {}

    public static func weakObjects() -> NSHashTable<ObjectType> { NSHashTable() }

    public func add(_ object: ObjectType?) {
        guard let object else { return }
        lock.lock(); defer { lock.unlock() }
        prune()
        entries[ObjectIdentifier(object)] = Weak(object: object)
    }

    public func remove(_ object: ObjectType?) {
        guard let object else { return }
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(object)] = nil
    }

    public func contains(_ object: ObjectType?) -> Bool {
        guard let object else { return false }
        lock.lock(); defer { lock.unlock() }
        return entries[ObjectIdentifier(object)]?.object === object
    }

    public var allObjects: [ObjectType] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.compactMap(\.object)
    }

    public var count: Int { allObjects.count }

    public func removeAllObjects() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    /// Entries whose object has gone, so a recycled address cannot answer.
    private func prune() {
        entries = entries.filter { $0.value.object != nil }
    }
}
#endif
