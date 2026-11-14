import PlatformShim
import UIKit

/// `Source/Utils/HapticsManager.swift` on Android: the same API and settings,
/// for the same callers. The game's own file plays its feedback only under
/// `#if os(iOS)` (Apple TV has none) and offers it on phones alone (its
/// idiom), where Android offers it wherever the device has a vibrator,
/// tablets too (`VibrationSupport`); here the generators always play, and
/// the shim's UIKit generators hand each kind to the vibrator
/// (`SystemServices.haptic`, `DeviceServices.java`).
final class HapticsManager {
    static let shared = HapticsManager()

    /// The settings' Vibration switch shows, and feedback plays, only here.
    static var isSupported: Bool {
        #if DEBUG
        let override = UserDefaults.standard.string(forKey: VibrationSupport.argument)
        #else
        let override: String? = nil
        #endif
        return VibrationSupport.isSupported(hasVibrator: SystemServices.hasVibrator, override: override)
    }

    static var isHapticsEnabled: Bool {
        get { isSupported && (UserDefaults.standard.object(forKey: Key.hapticsEnabled) as? Bool ?? true) }
        set { ICloudSyncManager.shared.set(newValue, forKey: Key.hapticsEnabled) }
    }

    private enum Key {
        static let hapticsEnabled = "settings.hapticsEnabled"
    }

    /// What the player's devices keep the same.
    static let syncedKeys: [String: ICloudSyncManager.Merge] = [Key.hapticsEnabled: .latest]

    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {}

    static func loadSettings() {
        _ = shared
    }

    static func lightImpact() {
        guard isHapticsEnabled else { return }
        shared.lightImpactGenerator.impactOccurred()
    }

    static func mediumImpact() {
        guard isHapticsEnabled else { return }
        shared.mediumImpactGenerator.impactOccurred()
    }

    static func softImpact() {
        guard isHapticsEnabled else { return }
        shared.softImpactGenerator.impactOccurred()
    }

    static func selectionChanged() {
        guard isHapticsEnabled else { return }
        shared.selectionGenerator.selectionChanged()
    }

    static func success() {
        guard isHapticsEnabled else { return }
        shared.notificationGenerator.notificationOccurred(.success)
    }

    static func warning() {
        guard isHapticsEnabled else { return }
        shared.notificationGenerator.notificationOccurred(.warning)
    }
}
