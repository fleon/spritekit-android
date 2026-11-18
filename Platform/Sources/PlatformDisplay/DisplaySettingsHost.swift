#if SPRITEKIT_SHIM
import Foundation
import SpriteKitShim

/// The shell's display members of `GameHost`, answered from
/// `DisplaySettings`: a game's Android controller that adopts this as well
/// as `GameHost` needn't write them (its own, where it has them, win). The
/// shell's renderer then applies the same frame-rate and graphics settings,
/// and the same Auto, as `RenderScaleController` does on Apple.
public protocol DisplaySettingsHost {}

extension DisplaySettingsHost {
    public static var displayChoices: (rate: Int, scales: [Double], governs: Bool, decided: Double?) {
        DisplaySettings.choices.tuple
    }

    public static var pinnedRenderScale: Double? { DisplaySettings.pinnedRenderScale }

    public static func observeDisplayChoices(_ changed: @escaping @MainActor () -> Void) {
        DisplaySettings.observeChoices(changed)
    }

    public static func isMeasured(_ scene: SKScene?) -> Bool {
        DisplaySettings.configuration.isMeasured(scene)
    }

    public static func setRunning(rate: Int, scale: Double) {
        DisplaySettings.running = .init(rate: rate, scale: scale)
    }

    public static func noteAutoChosen(rate: Int, scale: Double) {
        DisplaySettings.noteAutoChosen(.init(rate: rate, scale: scale))
    }
}
#endif
