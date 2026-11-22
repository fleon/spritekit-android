import Foundation
import Macros
import Testing
@testable import PlatformCore

/// `@LaunchArgument`'s expansions, type-checked and read against a scratch
/// defaults suite.
private nonisolated func launchReader(enabled: Bool) -> LaunchArgumentReader {
    let name = "LaunchArgumentMacroTests"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let values: [String: Any] = [
        "Flag": "YES", "Name": "level-3", "Count": "2", "Slow": "8", "Centre": "0.25", "Size": "1376x1032",
        "Tour": "a, b,c", "Times": "0,1.4,2.8", "Frames": "0,600,x", "Mode": "fast", "Modes": "fast,x,slow",
        "Step": "1/30", "Stills": "one;two", "Seed": "18446744073709551615", "Link": "https://example.com/a",
        "Off": "NO",
    ]
    for (key, value) in values { defaults.set(value, forKey: key) }
    return LaunchArgumentReader(defaults: defaults, enabled: enabled)
}

private enum Mode: String { case slow, fast }

private enum Debug {
    static let reader = launchReader(enabled: true)

    @LaunchArgument("Flag") static var flag: Bool
    @LaunchArgument("Missing") static var missingFlag: Bool
    @LaunchArgument("Missing", unset: true) static var unsetFlag: Bool
    @LaunchArgument("Off", unset: true) static var offFlag: Bool
    @LaunchArgument("Name") static var name: String?
    @LaunchArgument("Count") static var count: Int?
    @LaunchArgument("Missing") static var clears: Int
    @LaunchArgument("Slow", unset: 1) static var slowdown: Double
    @LaunchArgument("Missing", unset: 1) static var defaultSlowdown: Double
    @LaunchArgument("Centre") static var centre: CGFloat?
    @LaunchArgument("Missing", release: 1) static var scale: CGFloat
    @LaunchArgument("Size") static var size: CGSize?
    @LaunchArgument("Tour") static var tour: [String]?
    @LaunchArgument("Missing") static var script: [String]
    @LaunchArgument("Times") static var times: [TimeInterval]
    @LaunchArgument("Frames") static var frames: [Int]?
    @LaunchArgument("Mode") static var mode: Mode?
    @LaunchArgument("Missing", unset: Mode.slow) static var defaultMode: Mode
    @LaunchArgument("Modes") static var modes: [Mode]?
    @LaunchArgument("Step", as: .fraction) static var step: TimeInterval?
    @LaunchArgument("Stills", separator: ";") static var stills: [String]?
    @LaunchArgument("Seed") static var seed: UInt64?
    @LaunchArgument("Link") static var link: URL?
}

/// A release build's reader: every read takes its fixed value.
private nonisolated enum Release {
    static let reader = launchReader(enabled: false)

    @LaunchArgument("Flag") static var flag: Bool
    @LaunchArgument("Flag", release: true) static var releaseFlag: Bool
    @LaunchArgument("Missing", unset: false, release: true) static var unsetFlag: Bool
    @LaunchArgument("Name") static var name: String?
    @LaunchArgument("Name", release: "shipped") static var releaseName: String?
    @LaunchArgument("Slow", unset: 1) static var slowdown: Double
    @LaunchArgument("Slow", unset: 1, release: 2) static var releaseSlowdown: Double
    @LaunchArgument("Centre", release: 0.5) static var centre: CGFloat?
    @LaunchArgument("Mode", release: Mode.slow) static var mode: Mode?
}

/// A reader of the instance's own, named by `reader:`.
private struct Options {
    let launch: LaunchArgumentReader

    @LaunchArgument("Count", reader: "launch") var count: Int?
}

/// `nonisolated` reads, in a main-actor type, of a `nonisolated` reader.
private enum Isolated {
    nonisolated static let reader = launchReader(enabled: true)

    @LaunchArgument("Flag") nonisolated static var flag: Bool
}

struct LaunchArgumentMacroTests {
    @Test func readsThroughTheDeclaredType() {
        #expect(Debug.flag && !Debug.missingFlag && Debug.unsetFlag && !Debug.offFlag)
        #expect(Debug.name == "level-3")
        #expect(Debug.count == 2 && Debug.clears == 0)
        #expect(Debug.slowdown == 8 && Debug.defaultSlowdown == 1)
        #expect(Debug.centre == 0.25 && Debug.scale == 1)
        #expect(Debug.size == CGSize(width: 1376, height: 1032))
        #expect(Debug.tour == ["a", "b", "c"] && Debug.script == [])
        #expect(Debug.times == [0, 1.4, 2.8])
        #expect(Debug.frames == [0, 600])
        #expect(Debug.mode == .fast && Debug.defaultMode == .slow)
        #expect(Debug.modes == [.fast, .slow])
        #expect(Debug.step == 1.0 / 30)
        #expect(Debug.stills == ["one", "two"])
        #expect(Debug.seed == UInt64.max)
        #expect(Debug.link == URL(string: "https://example.com/a"))
        #expect(Options(launch: Debug.reader).count == 2)
        #expect(Isolated.flag)
    }

    @Test func releaseBuildsTakeTheirFixedValues() {
        #expect(!Release.flag && Release.releaseFlag && Release.unsetFlag)
        #expect(Release.name == nil && Release.releaseName == "shipped")
        #expect(Release.slowdown == 1 && Release.releaseSlowdown == 2)
        #expect(Release.centre == 0.5)
        #expect(Release.mode == .slow)
    }
}
