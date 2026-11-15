import Android
import CAndroidShell
import Foundation
import GLESBackend
import ShellCore

/// Runs libdispatch's workers below the frame thread, as Apple's QoS does.
///
/// A Linux thread takes the niceness of the thread that starts it, so the
/// workers the game builds scenes and pages on came up at the frame thread's
/// own -4 (SDL's) and took the CPU from it as equals while a scene built.
/// libdispatch on Linux has no QoS to ask for and no hook as a worker starts,
/// so the frame loop looks for new threads (`/proc/self/stat`'s count, read
/// each frame, then `/proc/self/task` when it grows) and sets each new
/// `DispatchWorker` to `niceness`. Workers that workers start inherit it.
/// The frame thread's alone.
nonisolated enum WorkerPriority {
    private static var niceness: Int32? { WorkerNiceness.setting }

    nonisolated(unsafe) private static var threadCount = 0
    nonisolated(unsafe) private static var seen: Set<Int32> = []
    nonisolated(unsafe) private static var lowered = 0
    /// New threads still wearing the name of the thread that started them,
    /// as a worker does until libdispatch names it, with the scans left to
    /// look at them again.
    nonisolated(unsafe) private static var unnamed: [Int32: Int] = [:]
    /// How many frames a new thread has to take its own name.
    static let namingScans = 30

    /// Called once a frame: cheap unless a thread has started since the
    /// last, or one that has hasn't taken its own name yet.
    static func update() {
        guard let niceness, let count = threadCountNow() else { return }
        guard count != threadCount || !unnamed.isEmpty else { return }
        threadCount = count
        guard let directory = opendir("/proc/self/task") else { return }
        defer { closedir(directory) }
        let own = gettid()
        var present: Set<Int32> = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard let tid = Int32(name) else { continue }
            present.insert(tid)
            guard !seen.contains(tid) || unnamed[tid] != nil, tid != own else { continue }
            let comm = read("/proc/self/task/\(tid)/comm") ?? ""
            if comm.hasPrefix("DispatchWorker") {
                unnamed.removeValue(forKey: tid)
                if setpriority(PRIO_PROCESS, id_t(tid), niceness) == 0 {
                    lowered += 1
                    if lowered == 1 { Log.info("workers run at niceness \(niceness)") }
                }
            } else if comm.hasPrefix("SDLThread") {
                // The frame thread's name: one it started, not named yet.
                let left = (unnamed[tid] ?? namingScans) - 1
                unnamed[tid] = left > 0 ? left : nil
            } else {
                unnamed.removeValue(forKey: tid)
            }
        }
        unnamed = unnamed.filter { present.contains($0.key) }
        seen = present
    }

    /// The process's thread count, field 20 of `/proc/self/stat`.
    private static func threadCountNow() -> Int? {
        guard let stat = read("/proc/self/stat") else { return nil }
        return threadCount(inStat: stat)
    }

    /// Field 20 of a `/proc/<pid>/stat` line. The command name (field 2)
    /// may hold spaces and brackets, so fields count from its last `)`.
    static func threadCount(inStat stat: String) -> Int? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // Field 3 (the state) is the first after the name.
        return fields.count > 17 ? Int(fields[17]) : nil
    }

    nonisolated(unsafe) private static var buffer = [UInt8](repeating: 0, count: 1024)

    private static func read(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let length = buffer.withUnsafeMutableBytes { Android.read(fd, $0.baseAddress, $0.count) }
        guard length > 0 else { return nil }
        return String(decoding: buffer[0 ..< length], as: UTF8.self)
    }
}
