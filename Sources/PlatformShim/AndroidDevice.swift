import Foundation

/// The device as a game's diagnostics name it, where iOS has TestFlight's
/// feedback: its maker and model ("Google Pixel 9"), its Android version
/// ("17") and whether it's an emulator, which gains `-Playtest NO` unless
/// given `-Playtest YES`, as a game knows an iOS simulator at compile time.
/// `MainActivity` puts them in the environment before the Swift libraries
/// load (`SKA_DEVICE_MODEL`, `SKA_OS_VERSION`, `SKA_EMULATOR`).
public struct AndroidDevice: Equatable, Sendable {
    public let model: String
    public let osVersion: String
    public let isEmulator: Bool

    /// This device, as `MainActivity` described it.
    public static let current = AndroidDevice(environment: ProcessInfo.processInfo.environment)

    /// The argument an emulator's launch gains unless it names it, which a
    /// game reads to tell whether to record playtests: `Playtest`.
    public static let playtestArgument = "Playtest"

    public init(environment: [String: String]) {
        model = environment["SKA_DEVICE_MODEL"] ?? ""
        osVersion = environment["SKA_OS_VERSION"] ?? ""
        isEmulator = environment["SKA_EMULATOR"] == "1"
    }

    /// The launch's arguments as an emulator takes them: `-Playtest NO`
    /// unless they say otherwise, since a game only knows an iOS simulator at
    /// compile time.
    public func arguments(_ arguments: [String: Any]) -> [String: Any] {
        guard isEmulator, arguments[Self.playtestArgument] == nil else { return arguments }
        var arguments = arguments
        arguments[Self.playtestArgument] = false
        return arguments
    }
}

/// Whether this build is a beta, for Play's testing tracks (internal, closed
/// and open), where a game may turn on what only its testers get (remote
/// content, playtest records). Play can't tell an app which track installed
/// it, so it's chosen when the app is built, as one of the app's build
/// properties, and the Gradle project writes it into the app's assets, where
/// `MainActivity` reads it into the environment (`SKA_BETA`). A production
/// build is built with it off, never promoted from a testing track.
public struct BetaBuild: Equatable, Sendable {
    public let isOn: Bool

    public static let current = BetaBuild(environment: ProcessInfo.processInfo.environment)

    /// The argument a game reads to load remote levels rather than its
    /// bundled ones, `DesignerLevels`, beside `Playtest`.
    public static let feedArgument = "DesignerLevels"

    public init(environment: [String: String]) {
        isOn = environment["SKA_BETA"] == "1"
    }

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    /// The launch's arguments as this build takes them: with beta off,
    /// `-DesignerLevels NO` and `-Playtest NO` unless they say otherwise, so
    /// a debug build can still be pointed at the remote levels and record
    /// playtests. A store build reads no arguments, and a game checks `isOn`
    /// itself.
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
        isOn ? "beta build: the launch's arguments as given"
             : "not a beta build: -DesignerLevels NO and -Playtest NO unless the launch names them"
    }
}
