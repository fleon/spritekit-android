import Foundation

// Stands in for the system `os` module on Android. The game imports it in
// six files, and uses exactly one thing from it: `OSAllocatedUnfairLock`,
// which guards the state scenes read off the main thread (the level feed,
// a page's generation, a film's cancel flag).
//
// `os_unfair_lock` is Darwin's; the portable equivalent with the same
// semantics — non-recursive, no fairness guarantee, cheap when uncontended —
// is a pthread mutex, which is what Foundation's `NSLock` is on Linux and
// Android. The surface is the Swift one, so the call sites compile unchanged.

/// A value behind a lock, handed to a closure for the length of one call.
/// Matches the shape the game uses: `init(initialState:)` and `withLock`.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    /// `withLock` over a lock with no state of its own.
    @discardableResult
    public func withLock<R>(_ body: () throws -> R) rethrows -> R where State == Void {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public extension OSAllocatedUnfairLock where State == Void {
    convenience init() {
        self.init(initialState: ())
    }
}
