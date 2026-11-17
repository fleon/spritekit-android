import Foundation
import GameKit
import PlatformShim
import SwitchlingsStore
import UIKit

/// Puts the game's platform managers on Google Play and the device, once,
/// before `AppDelegate`'s launch work starts them: the Android half of what
/// StoreKit, GameKit and iCloud are on Apple. Every backend talks through
/// `PlatformChannel.shared`, which the shell installs; with none (a host
/// build) the managers keep the backends they start with, which keep
/// everything on the device.
enum AndroidPlatformServices {
    static func install() {
        let channel = PlatformChannel.shared
        if LaunchArguments.simulatesPurchases {
            StoreManager.billing = SimulatedBilling()
        } else if let channel {
            StoreManager.billing = PlayBilling(channel: channel, products: [Entitlements.fullGameID])
        }
        guard let channel else { return }
        installDevice(channel)
        installPlayGames(channel)
    }

    /// Play Games: achievements, the player for a credit, and Saved Games
    /// under `ICloudSyncManager`. Only with the generated mapping in the APK
    /// (`Tools/Play/games.js`), which also names the project the manifest
    /// gives Play Games: without it, Play Games was never set up for this
    /// build, and achievements and saved data stay on the device.
    private static func installPlayGames(_ channel: PlatformChannel) {
        guard let url = Bundle.main.url(forResource: "PlayGamesAchievements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let mapping = PlayGamesMapping(data: data)
        else { return }
        let games = PlayGamesAchievements(channel: channel, mapping: mapping)
        // The beta's solve log names a signed-in player by their Play Games ID.
        games.identityChanged = { identity in
            Task { @MainActor in GKLocalPlayer.local.update(identity) }
        }
        if !LaunchArguments.keepsGameCenterOff { GameCenterManager.service = games }
        guard !LaunchArguments.keepsICloudOff else { return }
        let cloud = PlaySavedGamesCloud(channel: channel)
        games.signInChanged = { cloud.signInChanged($0) }
        ICloudSyncManager.cloud = cloud
        // As `SceneDelegate` asks iCloud for news coming back to the front,
        // and Android may end a backgrounded app without a word.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            cloud.flush()
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            ICloudSyncManager.shared.synchronize()
        }
        if LaunchArguments.keepsGameCenterOff { games.start {} }
    }

    /// Haptics, battery saver and audio focus, and the battery and
    /// connection the beta's solve log records (`DeviceServices.java`).
    private static func installDevice(_ channel: PlatformChannel) {
        SystemServices.haptic = { kind in channel.call("device.haptic", ["kind": kind]) }
        SystemServices.batteryLevel = {
            channel.call("device.battery")?.double("level").map(Float.init) ?? -1
        }
        SystemServices.connection = { channel.call("device.connection")?["kind"] as? String }
        UIImage.jpegToPNG = { jpeg in
            (channel.call("device.jpegToPng", ["data": jpeg.base64EncodedString()])?["data"] as? String)
                .flatMap { Data(base64Encoded: $0) }
        }
        UIImage.pngToJPEG = { png, quality in
            (channel.call("device.pngToJpeg", ["data": png.base64EncodedString(), "quality": Int(quality * 100)])?["data"] as? String)
                .flatMap { Data(base64Encoded: $0) }
        }
        if let state = channel.call("device.state") {
            SystemServices.lowPowerMode = state.bool("powerSave") ?? false
            SystemServices.hasVibrator = state.bool("haptics") ?? false
        }
        channel.on("device") { event, body in
            switch event {
            case "powerSave":
                let enabled = body.bool("enabled") ?? false
                guard enabled != SystemServices.lowPowerMode else { return }
                SystemServices.lowPowerMode = enabled
                // What iOS posts as Low Power Mode changes: the frame rate
                // follows (`DisplaySettings`, through the controller).
                NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            case "audio":
                MainActor.assumeIsolated {
                    AudioManager.audioFocusDidChange(
                        otherAudio: body.bool("otherAudio") ?? false,
                        interrupted: body.bool("interrupted") ?? false
                    )
                }
            default:
                break
            }
        }
    }
}
