#if SPRITEKIT_SHIM
import Foundation
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Which thread the game is allowed to call itself the main one on.
///
/// Games assert it: code that primes a shader may open with
/// `precondition(Thread.isMainThread)` — priming a shader waits for the GPU,
/// so it has to happen on the thread that draws — and code that builds off
/// the main thread comes back to it, because on Apple the thread that
/// draws **is** the process's first thread.
///
/// On Android it is not. SDL's Java side runs `SDL_main` on a thread of its
/// own called `SDLThread`, and that is where every frame, every action and
/// every draw call happens. The process's first thread is Android's UI
/// thread, which the game never touches. So `Thread.isMainThread` is false
/// on the only thread the game runs on, and the precondition traps:
///
///     signal 5 (SIGTRAP) … tid: 5578, name: SDLThread
///     Swift runtime failure: precondition failure
///     (the game's function that primed a shader)
///
/// The game's sources compile unchanged, so Foundation's answer has to be
/// the right one instead. On Android, corelibs Foundation answers
/// `Thread.isMainThread` out of CoreFoundation's `_CFIsMainThread`, which is
/// `gettid() == getpid()` — "is this the process's first thread" — and
/// nothing can make that true of a thread Java started.
///
/// What can be done is to answer it ourselves. `_CFIsMainThread` is an
/// ordinary exported C function, called through the PLT, and
/// `libAndroidShell.so` is searched before `libFoundation.so` when those
/// references are bound, so a definition here takes its place for the whole
/// process. Until `claim()` is called it answers exactly as CoreFoundation's
/// does, so the substitution changes nothing by itself; `claim()` is what
/// moves "main" to the calling thread.
///
/// That is the truth for this app: SDL's thread is the one the game lives
/// on. It is a loader-order trick all the same, so `claim()` checks that it
/// took and the shell says so loudly if it did not — what follows otherwise
/// is a trap on the first main-thread check.
public enum MainThread {
    /// The thread the game runs on, once it has said so. Read by
    /// `_CFIsMainThread` below, which is why it is not private.
    nonisolated(unsafe) static var claimed: pthread_t?

    /// Whether the claim has been made and took.
    public private(set) nonisolated(unsafe) static var isClaimed = false

    /// Tells Foundation that the calling thread is the main one. Call it as
    /// early as the process can.
    @discardableResult
    public static func claim() -> Bool {
        claimed = pthread_self()
        isClaimed = Thread.isMainThread
        return isClaimed
    }
}

#if !canImport(Darwin)
/// Stands in for CoreFoundation's own, as `MainThread` explains. Before a
/// claim it answers the same way CoreFoundation's does.
@_cdecl("_CFIsMainThread")
public func skaIsMainThread() -> UInt8 {
    if let claimed = MainThread.claimed {
        return pthread_equal(pthread_self(), claimed) != 0 ? 1 : 0
    }
    return gettid() == getpid() ? 1 : 0
}
#endif
#endif
