#if SPRITEKIT_SHIM
import Foundation
import PlatformShim
import SpriteKitShim
import Testing
@testable import PlatformAndroid

/// The app's Java as the wiring meets it: what each call answers at once,
/// and every call made.
private final class FakeJava {
    var calls: [(name: String, arguments: [String: Any])] = []
    var answers: [String: [String: Any]] = [
        "games.available": ["available": true],
        "device.state": ["powerSave": true, "haptics": true],
        "device.battery": ["level": 0.5],
    ]

    lazy var channel = PlatformChannel { [unowned self] name, data in
        let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        calls.append((name, arguments))
        return answers[name].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    func names() -> [String] { calls.map(\.name) }
}

private let mapping = PlayGamesMapping(
    applicationID: "1",
    achievements: ["achievement.one": .init(id: "play-one")],
    leaderboards: ["board.one": "play-board"]
)

@MainActor
@Suite(.serialized)
struct AndroidWiringTests {
    private func configuration(_ java: FakeJava, _ center: NotificationCenter) -> AndroidPlatformServices.Configuration {
        var configuration = AndroidPlatformServices.Configuration()
        configuration.channel = java.channel
        configuration.playGames = mapping
        configuration.notificationCenter = center
        return configuration
    }

    @Test("Each backend goes to the receiver the game names")
    func receivers() {
        let java = FakeJava()
        let center = NotificationCenter()
        var achievements: AchievementsBackend?
        var leaderboards: LeaderboardsBackend?
        var cloud: CloudKeyValueStore?
        var billing: BillingBackend?
        var config = configuration(java, center)
        config.achievements = { achievements = $0 }
        config.leaderboards = { leaderboards = $0 }
        config.cloud = { cloud = $0 }
        config.billing = .init(products: ["product.one"]) { billing = $0 }

        let installed = AndroidPlatformServices.install(config)

        #expect(achievements === installed.achievements)
        #expect(leaderboards === installed.leaderboards)
        #expect(cloud === installed.cloud)
        #expect(billing is PlayBilling)
        // The Game Center manager starts sign-in itself.
        #expect(!java.names().contains("games.start"))
    }

    @Test("Without a mapping, Play Games is left alone; simulated purchases need no channel")
    func noPlayGames() {
        var billing: BillingBackend?
        var achievements: AchievementsBackend?
        var config = AndroidPlatformServices.Configuration()
        config.channel = nil
        config.playGames = nil
        config.achievements = { achievements = $0 }
        config.billing = .init(products: ["product.one"], simulated: true) { billing = $0 }

        AndroidPlatformServices.install(config)

        #expect(billing is SimulatedBilling)
        #expect(achievements == nil)
    }

    @Test("Saved Games follows sign-in, flushes in the background and asks for news in the foreground")
    func cloudLifecycle() {
        let java = FakeJava()
        let center = NotificationCenter()
        var config = configuration(java, center)
        config.cloud = { _ in }

        AndroidPlatformServices.install(config)
        // Nobody took achievements, so the wiring signs in for the cloud.
        #expect(java.names().contains("games.start"))

        java.channel.deliver([["service": "games", "event": "signIn", "signedIn": true]])
        #expect(java.names().filter { $0 == "games.openSnapshot" }.count == 1)
        java.channel.deliver([["service": "games", "event": "snapshotOpened", "request": 1, "ok": false]])

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(java.names().filter { $0 == "games.openSnapshot" }.count == 2)
    }

    @Test("The player signed in is passed on")
    func player() {
        let java = FakeJava()
        var player: (id: String, name: String)?
        var config = configuration(java, NotificationCenter())
        config.player = { player = $0 }
        config.achievements = { _ in }

        AndroidPlatformServices.install(config)
        java.channel.deliver([
            ["service": "games", "event": "signIn", "signedIn": true],
            ["service": "games", "event": "identity", "id": "p1", "name": "Player"],
        ])

        #expect(player?.id == "p1")
        #expect(player?.name == "Player")
    }

    @Test("Haptics, battery saver, audio focus, diagnostics and the status bar reach the device")
    func device() {
        let java = FakeJava()
        let center = NotificationCenter()
        var focus: (Bool, Bool)?
        var statusBarVisible = true
        let statusBarChanged = Notification.Name("test.statusBar")
        var config = configuration(java, center)
        config.playGames = nil
        config.audioFocusChanged = { focus = ($0, $1) }
        config.diagnostics = true
        config.statusBar = .init(isVisible: { statusBarVisible }, changed: statusBarChanged)

        AndroidPlatformServices.install(config)
        #expect(Device.lowPowerMode)
        #expect(Device.hasVibrator)
        #expect(Device.batteryLevel() == 0.5)

        Device.haptic("light")
        #expect(java.calls.last?.name == "device.haptic")
        #expect(java.calls.last?.arguments["kind"] as? String == "light")

        var powerChanges = 0
        let observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            powerChanges += 1
        }
        java.channel.deliver([
            ["service": "device", "event": "powerSave", "enabled": false],
            ["service": "device", "event": "powerSave", "enabled": false],
            ["service": "device", "event": "audio", "otherAudio": true, "interrupted": false],
        ])
        center.removeObserver(observer)
        #expect(!Device.lowPowerMode)
        #expect(powerChanges == 1)
        #expect(focus.map { [$0.0, $0.1] } == [true, false])

        #expect(java.calls.last(where: { $0.name == "device.statusBar" })?.arguments["visible"] as? Bool == true)
        statusBarVisible = false
        center.post(name: statusBarChanged, object: nil)
        #expect(java.calls.last(where: { $0.name == "device.statusBar" })?.arguments["visible"] as? Bool == false)
    }
}
#endif
