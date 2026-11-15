#if SPRITEKIT_SHIM || !canImport(Darwin)
import Foundation

/// `CACurrentMediaTime()` on Android.
///
/// The game reads this clock in `MediaClock`, in every shader's `u_time` and
/// in the board's action timings, so there must be exactly one of it —
/// `Android/Shell`'s note on the renderer seam says the same thing about
/// `ShellClock`. The two are the same clock: the shell installs its own as
/// the source as it starts, so nothing has to choose between them.
///
/// Left alone it is monotonic seconds since the first call. Counting from
/// first use rather than from boot keeps the numbers small, which matters
/// because `u_time` reaches a shader as a 32-bit float: a device up for a
/// month would be handing shaders a value with centisecond resolution.
public enum MediaTime {
    /// Where the time comes from. The shell sets this before anything draws.
    public nonisolated(unsafe) static var source: () -> TimeInterval = defaultSource

    /// Set once, by whichever thread asks first (a share film's asks off
    /// the main one): a `static let` is initialised exactly once.
    private static let base = monotonic()

    public static func defaultSource() -> TimeInterval {
        let base = self.base
        return monotonic() - base
    }

    private static func monotonic() -> TimeInterval {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return TimeInterval(now.tv_sec) + TimeInterval(now.tv_nsec) / 1_000_000_000
    }
}

/// The game's `import QuartzCore` resolves to the module of that name in
/// `Compat`, which re-exports this.
public func CACurrentMediaTime() -> TimeInterval {
    MediaTime.source()
}
#endif
