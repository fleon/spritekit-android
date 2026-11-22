#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation
import PlatformServices

/// Foundation's weak set, which corelibs Foundation leaves out.
/// A weak set of shaders, say, forgets a shader that goes away. Only the
/// weak flavour, and only the common calls.
public final class NSHashTable<ObjectType: AnyObject>: @unchecked Sendable {
    private struct Weak { weak var object: ObjectType? }
    private let entries = Locked([ObjectIdentifier: Weak]())

    private init() {}

    public static func weakObjects() -> NSHashTable<ObjectType> { NSHashTable() }

    public func add(_ object: ObjectType?) {
        guard let object else { return }
        entries.withLock { entries in
            // Entries whose object has gone, so a recycled address cannot answer.
            entries = entries.filter { $0.value.object != nil }
            entries[ObjectIdentifier(object)] = Weak(object: object)
        }
    }

    public func remove(_ object: ObjectType?) {
        guard let object else { return }
        entries.withLock { $0[ObjectIdentifier(object)] = nil }
    }

    public func contains(_ object: ObjectType?) -> Bool {
        guard let object else { return false }
        return entries.withLock { $0[ObjectIdentifier(object)]?.object === object }
    }

    public var allObjects: [ObjectType] {
        entries.withLock { $0.values.compactMap(\.object) }
    }

    public var count: Int { allObjects.count }

    public func removeAllObjects() {
        entries.withLock { $0.removeAll() }
    }
}
#endif
