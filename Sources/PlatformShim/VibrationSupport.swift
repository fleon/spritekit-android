import Foundation

/// Whether the game offers haptics (and a switch for them): where the
/// device has a vibrator (`Vibrator.hasVibrator()`),
/// whatever its size, rather than iOS's phones-only idiom test, which would
/// hide it on a vibrating tablet and show it on a phone without a motor.
/// `-Vibrator NO` (or `YES`), a debug launch argument of the runtime's
/// alone, stands in for the device's answer; release builds never read it.
public enum VibrationSupport {
    public static let argument = "Vibrator"

    public static func isSupported(hasVibrator: Bool, override: String? = nil) -> Bool {
        switch override?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: hasVibrator
        }
    }
}
