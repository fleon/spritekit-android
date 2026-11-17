#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// Runs the main actor's work on the thread the game lives on.
///
/// The loading screen builds the next scene on a background thread and
/// hands it back with `Task { @MainActor in … }`; the game does the same in
/// a dozen other places. On Apple the main actor's jobs go to the main
/// dispatch queue, which the main run loop drains. On Android the process's
/// first thread — the one libdispatch bound its main queue to as it loaded —
/// is Java's UI thread, which runs a Looper, not a CFRunLoop: nothing ever
/// drains that queue, so a main-actor job would simply never run. And the
/// game's main thread is SDL's anyway (`MainThread`).
///
/// So the main actor gets an executor of its own: a queue the shell's frame
/// loop drains at the top of every pass, on its own thread, where the run
/// loop would have between frames. Each job runs on that executor, which the
/// runtime takes as the main one, so `MainActor.assumeIsolated` inside one
/// holds.
///
/// The runtime is told through `swift_task_getMainExecutor_hook`, which the
/// shell sets in C (`ska_set_main_executor`, given
/// `executorReference`): its functions pass a two-word struct in Swift's
/// calling convention, which a `@convention(c)` Swift function cannot. The
/// enqueue hook beside it is never reached for the main actor since Swift
/// 6.2, and SE-0469's `ExecutorFactory`, the supported way, is not public in
/// the 6.4 Android SDK's interface.
///
/// `DispatchQueue.main.async` is not covered: that goes to libdispatch's own
/// queue, which the shell binds to the same thread and drains once a pass
/// (Android/README.md, "`DispatchQueue.main` runs on the game's thread").
public enum MainActorJobs {
    /// The executor's reference, as the runtime passes executors: the object
    /// and its `SerialExecutor` witness table (with flag bits).
    public static var executorReference: (identity: UnsafeRawPointer, implementation: UInt) {
        unsafeBitCast(FrameLoopExecutor.shared.asUnownedSerialExecutor(), to: (UnsafeRawPointer, UInt).self)
    }

    /// Whether the runtime's main actor runs on this executor now.
    public static var isInstalled: Bool {
        let main = unsafeBitCast(MainActor.sharedUnownedExecutor, to: (UnsafeRawPointer, UInt).self)
        return main.0 == executorReference.identity
    }

    /// Runs what has been sent to the main actor, and what those jobs send
    /// on in turn, a bounded number of rounds so a job that keeps sending
    /// itself cannot hold the frame.
    public static func drain(rounds: Int = 8) {
        FrameLoopExecutor.shared.drain(rounds: rounds)
    }
}

/// The main actor's executor here: a queue the frame loop empties.
final class FrameLoopExecutor: SerialExecutor, @unchecked Sendable {
    static let shared = FrameLoopExecutor()

    private let lock = NSLock()
    private var pending: [UnownedJob] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.lock()
        pending.append(unowned)
        lock.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(Thread.isMainThread, "not on the frame thread, where the main actor runs")
    }

    func drain(rounds: Int) {
        let executor = asUnownedSerialExecutor()
        for _ in 0 ..< rounds {
            lock.lock()
            let jobs = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            guard !jobs.isEmpty else { return }
            for job in jobs { job.runSynchronously(on: executor) }
        }
    }
}

#endif
