import Foundation
import SpriteKitShim

/// A public window onto the game's rig runtime.
///
/// Everything in `Source/` is internal — the game is one module and declares
/// nothing `public` — so `GameCompat`, which compiles those files as they
/// are, exports nothing by default. This is the smallest surface that lets
/// the app shell put a real `RigNode` on screen, and it is deliberately
/// thin: no behaviour of its own, nothing the game does not already do.
///
/// It grows as the shell needs more of the game. What it must not become is
/// a second way of doing something the game already does one way.
public enum GameRigs {
    /// The rig painted as `name` (`GardenA`, `LeverCastle`) at `unit` points
    /// per master pixel, or nil if `Assets/Rigs` has no such rig staged.
    public static func make(_ name: String, unit: CGFloat) -> SKNode? {
        RigNode(name: name, unit: unit)
    }

    /// What `node` can play.
    public static func animations(of node: SKNode) -> [String] {
        ((node as? RigNode)?.data.animations.keys).map { $0.sorted() } ?? []
    }

    /// Plays one of them.
    public static func play(_ node: SKNode, _ animation: String, loop: Bool = true, rise: CGFloat? = nil) {
        (node as? RigNode)?.play(animation, loop: loop, rise: rise)
    }

    /// How long it runs at its own pace.
    public static func duration(of node: SKNode, _ animation: String) -> TimeInterval {
        (node as? RigNode)?.duration(of: animation) ?? 0
    }

    /// How a Switchling's face is set: `open` (the live eyes, which a board
    /// puts on its painting), or one of the painted ones — `happy`, `sleep`,
    /// `dizzy`, `blink`. Named as `RigFaces.json` names them, which is how
    /// `RigData.faces(of:)` reads them too.
    public static func expression(_ node: SKNode, _ name: String) {
        guard let rig = node as? RigNode,
              let expression = CharacterExpression(rawValue: name.capitalized) else { return }
        rig.expression = expression
    }
}
