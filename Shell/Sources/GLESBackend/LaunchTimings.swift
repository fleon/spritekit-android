import Android
import Foundation
import ShellCore
import SpriteKitShim

/// How long a launch and each scene change take to show, to logcat
/// (`[timings] …`): each scene's first frame drawn, timed from the process's
/// start, the previous scene's first frame and the last touch, key or
/// button pressed (the one that asked for it, as a rule), and the launch's
/// long frames once its first half minute has passed. What the program cache
/// and the warm-ups are for is read from these lines.
nonisolated struct LaunchTimings {
    /// How long into the launch long frames are counted.
    static let window: TimeInterval = 30
    /// A frame this long or longer counts as long.
    static let longFrame: TimeInterval = 0.05

    /// When the process started, on `MediaTime`'s clock.
    private let processStart: TimeInterval
    private var lastScene: ObjectIdentifier?
    private var lastSceneFrame: TimeInterval?
    private var lastInput: TimeInterval?
    private var longest: TimeInterval = 0
    private var longFrames = 0
    private var reportedWindow = false

    init() {
        processStart = MediaTime.source() - Self.processAge()
    }

    /// Seconds since this process started: `/proc/self/stat`'s start time
    /// (clock ticks since boot) against the boot clock, else none.
    private static func processAge() -> TimeInterval {
        guard let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return 0 }
        // Fields after the command's closing parenthesis start at the third
        // (`state`); the start time is the 22nd.
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ticks = Double(fields[19]) else { return 0 }
        let started = ticks / Double(sysconf(Int32(_SC_CLK_TCK)))
        var now = timespec()
        clock_gettime(CLOCK_BOOTTIME, &now)
        return max(0, Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000 - started)
    }

    /// A touch, key or button pressed.
    mutating func pressed() {
        lastInput = MediaTime.source()
    }

    /// A frame drawn of `scene`, `interval` after the one before it.
    mutating func drew(_ scene: AnyObject?, interval: TimeInterval, extra: () -> String) {
        let now = MediaTime.source()
        let sinceLaunch = now - processStart
        if sinceLaunch < Self.window {
            longest = max(longest, interval)
            if interval >= Self.longFrame { longFrames += 1 }
        } else if !reportedWindow {
            reportedWindow = true
            Log.info(String(
                format: "[timings] first %.0f s: longest frame %.0f ms, %d frames of %.0f ms or more",
                Self.window, longest * 1000, longFrames, Self.longFrame * 1000
            ))
        }

        let id = scene.map(ObjectIdentifier.init)
        guard id != lastScene else { return }
        lastScene = id
        let name = scene.map { String(describing: type(of: $0)) } ?? "nothing"
        var line = String(format: "[timings] %@ first frame %.3f s after launch", name, sinceLaunch)
        if let lastSceneFrame { line += String(format: ", %.0f ms after the last scene's", (now - lastSceneFrame) * 1000) }
        if let lastInput { line += String(format: ", %.0f ms after the last input", (now - lastInput) * 1000) }
        let more = extra()
        if !more.isEmpty { line += "; " + more }
        Log.info(line)
        lastSceneFrame = now
    }
}
