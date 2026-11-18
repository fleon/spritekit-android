import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import QuartzCore
import SpriteKit
#endif

/// Debug markers: a line printed to standard output as each moment a
/// recording might cut to comes (`[marker] scene TitleScene`, and whatever
/// the game notes), so capture tools can time shots by them, and stills
/// held a set time after a marker. A game turns them on from its launch
/// arguments; `TransitionManager.show` notes each scene.
public enum Markers {
    /// Whether markers print.
    public static var prints = false
    /// Whether each carries the media clock (`CACurrentMediaTime`), so a
    /// tool can place lines that reach it late.
    public static var stamps = false

    /// The stills to hold, in order: after which marker, and how long after.
    public static var stills: [(marker: String, delay: TimeInterval)] = [] {
        didSet { pendingStills = Array(stills.enumerated()) }
    }

    /// Holds the view for still `n` (from 1) this long after its marker, on
    /// `scene`'s clock (else the view's scene's); the game's view sets it.
    public static var holdStill: ((Int, TimeInterval, SKScene?) -> Void)?

    /// Runs once its marker comes (a script that starts at `win`, say).
    public static var scriptTrigger: (marker: String, start: () -> Void)?

    private static var pendingStills: [(offset: Int, element: (marker: String, delay: TimeInterval))] = []

    /// `"move 3@0.05;celebrate@0.7"` as stills: markers and delays,
    /// `;`-separated, a delay of 0 where none is given.
    public static func parseStills(_ text: String) -> [(marker: String, delay: TimeInterval)] {
        text.split(separator: ";").map { entry in
            let parts = entry.split(separator: "@", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        }
    }

    /// `scene`: the scene the moment belongs to, if the view doesn't show it yet.
    public static func note(_ name: String, in scene: SKScene? = nil) {
        if let trigger = scriptTrigger, trigger.marker == name {
            scriptTrigger = nil
            trigger.start()
        }
        guard prints else { return }
        if stamps {
            print("[marker] \(name) @\(String(format: "%.4f", CACurrentMediaTime()))")
        } else {
            print("[marker] \(name)")
        }
        // A pipe (a Mac app's standard output) buffers whole blocks.
        fflush(stdout)
        let due = pendingStills.filter { $0.element.marker == name }
        pendingStills.removeAll { $0.element.marker == name }
        for (index, still) in due { holdStill?(index + 1, still.delay, scene) }
    }
}
