import Foundation
import PlatformServices

// Stands in for the system `os` module on Android, as far as one thing:
// `OSAllocatedUnfairLock`, which guards state that scenes read off the main
// thread.
//
// `os_unfair_lock` is Darwin's; the portable equivalent with the same
// semantics — non-recursive, no fairness guarantee, cheap when uncontended —
// is a pthread mutex, which is what `Locked`'s `NSLock` is on Linux and
// Android. The surface is the Swift one, so the call sites compile unchanged.

/// A value behind a lock, handed to a closure for the length of one call.
/// Apple's shape, as far as `init(initialState:)` and `withLock`.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let locked: Locked<State>

    public init(initialState: State) {
        locked = Locked(initialState)
    }

    @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try locked.withLock(body)
    }

    /// `withLock` over a lock with no state of its own.
    @discardableResult
    public func withLock<R>(_ body: () throws -> R) rethrows -> R where State == Void {
        try locked.withLock { _ in try body() }
    }
}

public extension OSAllocatedUnfairLock where State == Void {
    convenience init() {
        self.init(initialState: ())
    }
}
