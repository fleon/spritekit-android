import Foundation

/// The device as a game's diagnostics name it, where iOS has TestFlight's
/// feedback: its maker and model ("Google Pixel 9"), its Android version
/// ("17") and whether it's an emulator. `MainActivity` puts them in the
/// environment before the Swift libraries load (`SKA_DEVICE_MODEL`,
/// `SKA_OS_VERSION`, `SKA_EMULATOR`).
public struct AndroidDevice: Equatable, Sendable {
    public let model: String
    public let osVersion: String
    public let isEmulator: Bool

    /// This device, as `MainActivity` described it.
    public static let current = AndroidDevice(environment: ProcessInfo.processInfo.environment)

    public init(environment: [String: String]) {
        model = environment["SKA_DEVICE_MODEL"] ?? ""
        osVersion = environment["SKA_OS_VERSION"] ?? ""
        isEmulator = environment["SKA_EMULATOR"] == "1"
    }
}

/// Whether this build is a beta, for Play's testing tracks (internal, closed
/// and open), where a game may turn on what only its testers get. Play can't
/// tell an app which track installed it, so it's chosen when the app is
/// built, as one of the app's build properties, and the Gradle project
/// writes it into the app's assets, where `MainActivity` reads it into the
/// environment (`SKA_BETA`). A production build is built with it off, never
/// promoted from a testing track.
public struct BetaBuild: Equatable, Sendable {
    public let isOn: Bool

    public static let current = BetaBuild(environment: ProcessInfo.processInfo.environment)

    public init(environment: [String: String]) {
        isOn = environment["SKA_BETA"] == "1"
    }

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    /// What the launch log says of it.
    public var description: String {
        isOn ? "beta build" : "not a beta build"
    }
}

/// Launch arguments a game adds when the launch doesn't name them, keyed by
/// argument name (without its dash): on an emulator, which a game can only
/// tell from a phone at run time where Apple's simulator is known at compile
/// time, and in a build that isn't a beta. A game names its own
/// (`Shell.start(launchDefaults:)`); the launch's own arguments always win.
public struct LaunchDefaults: Equatable, Sendable {
    public var onEmulator: [String: Bool]
    public var outsideBeta: [String: Bool]

    public init(onEmulator: [String: Bool] = [:], outsideBeta: [String: Bool] = [:]) {
        self.onEmulator = onEmulator
        self.outsideBeta = outsideBeta
    }

    public static let none = LaunchDefaults()

    /// The launch's arguments with the defaults this device and build take
    /// added where the launch doesn't name them.
    public func apply(to arguments: [String: Any], device: AndroidDevice, beta: BetaBuild) -> [String: Any] {
        var arguments = arguments
        if device.isEmulator {
            for (key, value) in onEmulator where arguments[key] == nil { arguments[key] = value }
        }
        if !beta.isOn {
            for (key, value) in outsideBeta where arguments[key] == nil { arguments[key] = value }
        }
        return arguments
    }
}
