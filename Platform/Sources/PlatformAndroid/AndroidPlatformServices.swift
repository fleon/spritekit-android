#if SPRITEKIT_SHIM
import Foundation
import PlatformShim
import SpriteKitShim

/// Puts a game's platform managers on Google Play and the device, once,
/// before the game's launch work starts them: the Android half of what
/// StoreKit, GameKit, iCloud and the haptic engine are on Apple.
///
/// Every backend talks through `PlatformChannel.shared`, which the shell
/// installs. `install` makes each backend the game asks for and hands it to
/// the receiver the game names (its Game Center manager, its store, its
/// sync manager, `GKLeaderboard.backend`), so nothing here knows the
/// game's managers. With no channel (a host build) only simulated purchases
/// are made, and the managers keep the backends they start with, which keep
/// everything on the device.
public enum AndroidPlatformServices {
    public struct Configuration {
        public var channel: PlatformChannel? = PlatformChannel.shared
        /// The Game Center IDs as Play Games knows them, from the APK
        /// (`PlayGamesMapping.bundled()`). With none, Play Games was never
        /// set up for this build: achievements and saved data stay on the
        /// device.
        public var playGames: PlayGamesMapping? = .bundled()

        /// Receives Play Games' achievements (the Game Center manager's
        /// service). With none, sign-in still starts if a cloud is asked
        /// for, which needs it.
        public var achievements: ((AchievementsBackend) -> Void)?
        /// Receives Play Games' leaderboards (`GKLeaderboard.backend`).
        public var leaderboards: ((LeaderboardsBackend) -> Void)?
        /// Told the Play Games player now signed in, or nil
        /// (`GKLocalPlayer.local.update`).
        public var player: (((id: String, name: String)?) -> Void)?
        /// Receives Saved Games as the cloud saved data syncs through (the
        /// sync manager's, or `NSUbiquitousKeyValueStore.default.cloud`).
        /// What was written goes to Play as the game leaves the front, and
        /// news is asked for as it comes back.
        public var cloud: ((CloudKeyValueStore) -> Void)?

        /// Purchases, made whether or not there's a channel.
        public var billing: Billing?

        /// Told when audio focus changes (the `audio` event): whether other
        /// audio is playing, and whether a call interrupted the game.
        public var audioFocusChanged: ((_ otherAudio: Bool, _ interrupted: Bool) -> Void)?
        /// The settings' status bar switch, shown or hidden as it changes.
        public var statusBar: StatusBar?
        /// The battery and connection a game's diagnostics read
        /// (`device.battery`, `device.connection` in the app's Java).
        public var diagnostics = false
        /// JPEG to PNG and back through Android's codecs
        /// (`device.jpegToPng`, `device.pngToJpeg` in the app's Java).
        public var imageConversion = false

        /// Where the app's notifications are heard and posted.
        public var notificationCenter = NotificationCenter.default

        public init() {}
    }

    public struct Billing {
        public var products: [String]
        public var consumables: Set<String>
        /// Granted on the device without a store (a debug run's simulated
        /// purchases).
        public var simulated: Bool
        public var receive: (BillingBackend) -> Void

        public init(products: [String], consumables: Set<String> = [], simulated: Bool = false, receive: @escaping (BillingBackend) -> Void) {
            self.products = products
            self.consumables = consumables
            self.simulated = simulated
            self.receive = receive
        }
    }

    public struct StatusBar {
        public var isVisible: () -> Bool
        /// Posted when the switch changes.
        public var changed: Notification.Name

        public init(isVisible: @escaping () -> Bool, changed: Notification.Name) {
            self.isVisible = isVisible
            self.changed = changed
        }
    }

    /// What `install` made, kept alive with the observers it added.
    public final class Installed {
        public fileprivate(set) var achievements: PlayGamesAchievements?
        public fileprivate(set) var leaderboards: PlayGamesLeaderboards?
        public fileprivate(set) var cloud: PlaySavedGamesCloud?
        public fileprivate(set) var billing: BillingBackend?
        fileprivate var observers: [NSObjectProtocol] = []
        fileprivate let center: NotificationCenter

        fileprivate init(center: NotificationCenter) {
            self.center = center
        }

        deinit {
            for observer in observers { center.removeObserver(observer) }
        }
    }

    /// What the last `install` made.
    nonisolated(unsafe) public private(set) static var installed: Installed?

    @discardableResult
    public static func install(_ configuration: Configuration) -> Installed {
        let installed = Installed(center: configuration.notificationCenter)
        Self.installed = installed
        let channel = configuration.channel
        if let billing = configuration.billing {
            if billing.simulated {
                installed.billing = SimulatedBilling()
            } else if let channel {
                installed.billing = PlayBilling(channel: channel, products: billing.products, consumables: billing.consumables)
            }
            installed.billing.map(billing.receive)
        }
        guard let channel else { return installed }
        installDevice(channel, configuration, installed)
        if let mapping = configuration.playGames {
            installPlayGames(channel, mapping, configuration, installed)
        }
        return installed
    }

    private static func installPlayGames(
        _ channel: PlatformChannel, _ mapping: PlayGamesMapping, _ configuration: Configuration, _ installed: Installed
    ) {
        let games = PlayGamesAchievements(channel: channel, mapping: mapping)
        installed.achievements = games
        if let player = configuration.player {
            games.identityChanged = { player($0) }
        }
        if let receive = configuration.cloud {
            let cloud = PlaySavedGamesCloud(channel: channel)
            installed.cloud = cloud
            games.signInChanged = { cloud.signInChanged($0) }
            receive(cloud)
            // Android may end a backgrounded app without a word.
            let center = configuration.notificationCenter
            installed.observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { _ in
                cloud.flush()
            })
            installed.observers.append(center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { _ in
                cloud.synchronize()
            })
        }
        if let receive = configuration.leaderboards {
            let leaderboards = PlayGamesLeaderboards(channel: channel, mapping: mapping)
            installed.leaderboards = leaderboards
            receive(leaderboards)
        }
        if let receive = configuration.achievements {
            receive(games)
        } else if installed.cloud != nil {
            games.start {}
        }
    }

    private static func installDevice(_ channel: PlatformChannel, _ configuration: Configuration, _ installed: Installed) {
        Device.haptic = { kind in channel.call("device.haptic", ["kind": kind]) }
        if let state = channel.call("device.state") {
            Device.lowPowerMode = state.bool("powerSave") ?? false
            Device.hasVibrator = state.bool("haptics") ?? false
        }
        if configuration.diagnostics {
            Device.batteryLevel = { channel.call("device.battery")?.double("level").map(Float.init) ?? -1 }
            Device.connection = { channel.call("device.connection")?["kind"] as? String }
        }
        if configuration.imageConversion {
            UIImage.jpegToPNG = { jpeg in
                (channel.call("device.jpegToPng", ["data": jpeg.base64EncodedString()])?["data"] as? String)
                    .flatMap { Data(base64Encoded: $0) }
            }
            UIImage.pngToJPEG = { png, quality in
                (channel.call("device.pngToJpeg", ["data": png.base64EncodedString(), "quality": Int(quality * 100)])?["data"] as? String)
                    .flatMap { Data(base64Encoded: $0) }
            }
        }
        let center = configuration.notificationCenter
        let audioFocusChanged = configuration.audioFocusChanged
        channel.on("device") { event, body in
            switch event {
            case "powerSave":
                let enabled = body.bool("enabled") ?? false
                guard enabled != Device.lowPowerMode else { return }
                Device.lowPowerMode = enabled
                // As iOS posts Low Power Mode changing.
                center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            case "audio":
                audioFocusChanged?(body.bool("otherAudio") ?? false, body.bool("interrupted") ?? false)
            default:
                break
            }
        }
        if let statusBar = configuration.statusBar {
            let show = { _ = channel.call("device.statusBar", ["visible": statusBar.isVisible()]) }
            installed.observers.append(center.addObserver(forName: statusBar.changed, object: nil, queue: nil) { _ in show() })
            show()
        }
    }
}

public extension PlayGamesMapping {
    /// The mapping packed into the APK (`<name>.json`, written by the
    /// runtime's `Tools/Play/games.js`), if there is one.
    static func bundled(_ name: String = "PlayGamesAchievements", in bundle: Bundle = .main) -> PlayGamesMapping? {
        guard let url = bundle.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return PlayGamesMapping(data: data)
    }
}

#if canImport(Darwin)
/// The shim leaves UIKit's device glue out of a Mac host build, so the
/// wiring keeps its hooks here there, where its tests read them.
enum HostDevice {
    nonisolated(unsafe) static var haptic: (String) -> Void = { _ in }
    nonisolated(unsafe) static var hasVibrator = false
    nonisolated(unsafe) static var lowPowerMode = false
    nonisolated(unsafe) static var batteryLevel: () -> Float = { -1 }
    nonisolated(unsafe) static var connection: () -> String? = { nil }
}

typealias Device = HostDevice
#else
typealias Device = SystemServices
#endif
#endif
