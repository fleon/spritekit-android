import Foundation

/// State behind a lock, reached only for the length of one `withLock` call,
/// so nothing reads or writes it unlocked and every path out unlocks. The
/// lock is an `NSLock` (a pthread mutex): not recursive, so `body` must not
/// call `withLock` on the same value again.
public final class Locked<State>: @unchecked Sendable {
    @usableFromInline let lock = NSLock()
    @usableFromInline var state: State

    @inlinable
    public init(_ state: State) {
        self.state = state
    }

    /// Runs `body` with the state, locked.
    @inlinable @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

extension NSLock {
    /// Runs `body` with the lock held. Foundation has its own only from
    /// iOS 17 and macOS 14.
    @inlinable @discardableResult
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
