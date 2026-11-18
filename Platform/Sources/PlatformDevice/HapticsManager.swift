import Foundation
import PlatformServices
#if SPRITEKIT_SHIM
import PlatformShim
import SpriteKitShim
#else
import UIKit
#endif

/// A game's haptic feedback and the settings switch for it.
///
/// Feedback plays only where the device has it and the player hasn't
/// turned it off: on iPhones (UIKit's feedback generators, prepared again
/// after each use), on Android devices with a vibrator, tablets too (the
/// shell's vibrator, `SystemServices.haptic`), and nowhere on Apple TV or an
/// iPad. The switch is saved in `storage` under `settingKey`, on unless the
/// player turned it off; a game that syncs its settings hands in storage
/// that saves through its sync manager and lists `syncedKeys`.
public final class HapticsManager {
    /// The kinds of feedback, as UIKit names them.
    public enum Feedback: String, CaseIterable, Sendable {
        case light, medium, heavy, soft, rigid
        case selection
        case success, warning, error
    }

    public static let shared = HapticsManager()

    /// Where the switch is kept.
    public static var storage = ValueStorage.standard
    public static var settingKey = "settings.hapticsEnabled"
    /// What the switch is before the player touches it.
    public static var enabledByDefault = true

    /// Whether the device has haptics: the settings show the switch, and
    /// feedback plays, only then.
    public static var supported: () -> Bool = platformSupport

    /// Plays one kind of feedback; the platform's own unless a test or a
    /// game replaces it.
    public static var player: (Feedback) -> Void = { shared.play($0) }

    /// What the player's devices keep the same.
    public static var syncedKeys: [String: SyncEngine.Merge] { [settingKey: .latest] }

    public static var isSupported: Bool { supported() }

    public static var isHapticsEnabled: Bool {
        get { isSupported && (storage.object(settingKey) as? Bool ?? enabledByDefault) }
        set { storage.set(newValue, settingKey) }
    }

    #if os(iOS)
    private var generators: Generators?
    #endif

    private init() {}

    /// Readies the generators, so the first feedback isn't late.
    public static func loadSettings() {
        #if os(iOS)
        guard isSupported, shared.generators == nil else { return }
        shared.generators = Generators()
        #endif
    }

    public static func play(_ feedback: Feedback) {
        guard isHapticsEnabled else { return }
        player(feedback)
    }

    public static func lightImpact() { play(.light) }
    public static func mediumImpact() { play(.medium) }
    public static func heavyImpact() { play(.heavy) }
    public static func softImpact() { play(.soft) }
    public static func rigidImpact() { play(.rigid) }
    public static func selectionChanged() { play(.selection) }
    public static func success() { play(.success) }
    public static func warning() { play(.warning) }
    public static func error() { play(.error) }

    private func play(_ feedback: Feedback) {
        #if os(iOS)
        if generators == nil { generators = Generators() }
        generators?.play(feedback)
        #elseif SPRITEKIT_SHIM && !canImport(Darwin)
        // The kinds the shell's vibrator plays.
        switch feedback {
        case .light, .soft, .selection, .success, .warning: SystemServices.haptic(feedback.rawValue)
        case .medium, .heavy, .rigid: SystemServices.haptic(Feedback.medium.rawValue)
        case .error: SystemServices.haptic(Feedback.warning.rawValue)
        }
        #endif
    }

    private static func platformSupport() -> Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #elseif SPRITEKIT_SHIM && !canImport(Darwin)
        // `-Vibrator NO` (or YES) stands in for the device in a debug build.
        #if DEBUG
        let override = UserDefaults.standard.string(forKey: VibrationSupport.argument)
        #else
        let override: String? = nil
        #endif
        return VibrationSupport.isSupported(hasVibrator: SystemServices.hasVibrator, override: override)
        #else
        return false
        #endif
    }
}

#if os(iOS)
/// UIKit's generators, each prepared again once it has played.
private final class Generators {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    init() {
        for generator in [light, medium, soft, selection, notification] as [UIFeedbackGenerator] {
            generator.prepare()
        }
    }

    func play(_ feedback: HapticsManager.Feedback) {
        switch feedback {
        case .light: impact(light)
        case .medium: impact(medium)
        case .heavy: impact(heavy)
        case .soft: impact(soft)
        case .rigid: impact(rigid)
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        case .success: notify(.success)
        case .warning: notify(.warning)
        case .error: notify(.error)
        }
    }

    private func impact(_ generator: UIImpactFeedbackGenerator) {
        generator.impactOccurred()
        generator.prepare()
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notification.notificationOccurred(type)
        notification.prepare()
    }
}
#endif
