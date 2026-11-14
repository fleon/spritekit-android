import Foundation
import PlatformShim
import Testing

/// The Vibration switch shows, and haptics play, where the device has a
/// vibrator; `-Vibrator` stands in for it in a debug run.
@Suite struct VibrationSupportTests {
    @Test func followsTheVibrator() {
        #expect(VibrationSupport.isSupported(hasVibrator: true))
        #expect(!VibrationSupport.isSupported(hasVibrator: false))
    }

    @Test func aDebugOverrideWins() {
        for text in ["NO", "no", "false", "0", " NO "] {
            #expect(!VibrationSupport.isSupported(hasVibrator: true, override: text), "\(text)")
        }
        for text in ["YES", "true", "1"] {
            #expect(VibrationSupport.isSupported(hasVibrator: false, override: text), "\(text)")
        }
    }

    @Test func anythingElseKeepsTheDevicesAnswer() {
        for text in [nil, "", "maybe"] as [String?] {
            #expect(VibrationSupport.isSupported(hasVibrator: true, override: text), "\(text ?? "nil")")
            #expect(!VibrationSupport.isSupported(hasVibrator: false, override: text), "\(text ?? "nil")")
        }
    }
}
