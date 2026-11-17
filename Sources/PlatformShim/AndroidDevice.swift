import Foundation

/// The device as the beta's solve log names it (`PlaytestLog`), where iOS
/// has TestFlight's feedback: its maker and model ("Google Pixel 6"), its
/// Android version ("17") and whether it's an emulator, which records no
/// solves unless given `-Playtest YES`, as an iOS simulator records none.
/// `MainActivity` puts them in the environment before the Swift libraries
/// load (`SKA_DEVICE_MODEL`, `SKA_OS_VERSION`,
/// `SKA_EMULATOR`). Comes out with the solve log before the store
/// release.
public struct AndroidDevice: Equatable, Sendable {
    public let model: String
    public let osVersion: String
    public let isEmulator: Bool

    /// This device, as `MainActivity` described it.
    public static let current = AndroidDevice(environment: ProcessInfo.processInfo.environment)

    /// The argument an emulator's launch gains unless it names it: what
    /// `LaunchArguments.recordsPlaytests` reads, `Playtest`.
    public static let playtestArgument = "Playtest"

    public init(environment: [String: String]) {
        model = environment["SKA_DEVICE_MODEL"] ?? ""
        osVersion = environment["SKA_OS_VERSION"] ?? ""
        isEmulator = environment["SKA_EMULATOR"] == "1"
    }

    /// The launch's arguments as an emulator takes them: `-Playtest NO`
    /// unless they say otherwise, since `LaunchArguments` only knows an iOS
    /// simulator at compile time.
    public func arguments(_ arguments: [String: Any]) -> [String: Any] {
        guard isEmulator, arguments[Self.playtestArgument] == nil else { return arguments }
        var arguments = arguments
        arguments[Self.playtestArgument] = false
        return arguments
    }
}

/// Whether this build is a beta, for Play's testing tracks (internal, closed
/// and open), which play the Level Designer's live feed and post each clear
/// to its solve log (`DesignerFeed`, `PlaytestLog`), as every Apple build
/// does during the beta. Play can't tell an app which track installed it, so
/// it's chosen when the app is built (`-Pswitchlings.beta=true|false`, which
/// a release build must name) and Gradle writes it into the base module's
/// assets (`SwitchlingsBuild.json`), where `MainActivity` reads it into the
/// environment (`SKA_BETA`) and `play.js` checks an upload to a
/// testing track has it on. A production build is built with it off, never
/// promoted from a testing track.
public struct BetaBuild: Equatable, Sendable {
    public let isOn: Bool

    public static let current = BetaBuild(environment: ProcessInfo.processInfo.environment)

    /// What `LaunchArguments` reads for the feed and the solve log.
    public static let feedArgument = "DesignerLevels"

    public init(environment: [String: String]) {
        isOn = environment["SKA_BETA"] == "1"
    }

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    /// The launch's arguments as this build takes them: with beta off,
    /// `-DesignerLevels NO` and `-Playtest NO` unless they say otherwise, so
    /// a debug build can still be pointed at the feed and the solve log. A
    /// store build reads no arguments, and the two check `isOn` themselves.
    public func arguments(_ arguments: [String: Any]) -> [String: Any] {
        guard !isOn else { return arguments }
        var arguments = arguments
        for key in [Self.feedArgument, AndroidDevice.playtestArgument] where arguments[key] == nil {
            arguments[key] = false
        }
        return arguments
    }

    /// What the launch log says of it.
    public var description: String {
        isOn ? "beta build: plays the Level Designer's feed and posts solves"
             : "not a beta build: the bundled levels, no solves posted"
    }
}
