import Android
import CAndroidShell
import Foundation
import ShellCore

/// A thread of its own with a GL context sharing the frame thread's objects
/// (`ska_gl_share_create`), for work that would stall a frame:
/// linking programs (`ProgramBuilds`). It runs below the frame thread but
/// above the game's other workers (`WorkerPriority`): the loading screen's
/// warm-up draw waits for what it hasn't finished.
nonisolated final class GLBuilderThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var stopping = false
    private var stopped = false
    private let share: UnsafeMutableRawPointer

    /// Made on the frame thread with its context current; nil where EGL
    /// can't share it.
    init?() {
        guard let share = ska_gl_share_create() else { return nil }
        self.share = share
        let thread = Thread { [self] in run() }
        thread.name = "GLBuilder"
        thread.start()
    }

    /// Android's `THREAD_PRIORITY_DEFAULT`.
    static let niceness: Int32 = 0

    func async(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Finishes the job in hand, drops the rest and lets go of the context:
    /// on the frame thread, before its own context goes.
    func stop() {
        condition.lock()
        stopping = true
        jobs.removeAll()
        condition.broadcast()
        while !stopped { condition.wait() }
        condition.unlock()
        ska_gl_share_destroy(share)
    }

    private func run() {
        setpriority(PRIO_PROCESS, 0, Self.niceness)
        let current = ska_gl_share_make_current(share) == 1
        if !current { Log.error("the GL builder's context couldn't be made current") }
        while true {
            condition.lock()
            while jobs.isEmpty, !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                break
            }
            let job = jobs.removeFirst()
            condition.unlock()
            if current { job() }
        }
        ska_gl_share_release(share)
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

/// How far below the frame thread the game's workers run. Android's
/// `THREAD_PRIORITY_BACKGROUND`, a step more favourable: what an `AsyncTask`
/// runs at. `debug.<app>.workernice` overrides it, for measuring
/// (`off` leaves workers as they start).
public nonisolated enum WorkerNiceness {
    public static let standard: Int32 = 9

    /// Nil when it's off.
    public static let setting: Int32? = {
        guard let value = DebugProperty.string("workernice") else { return standard }
        return value == "off" ? nil : Int32(value) ?? standard
    }()

}
