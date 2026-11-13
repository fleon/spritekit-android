import Foundation
import SpriteKitShim

// Stand-ins for the two game helpers this slice reaches outside itself for.
// Everything else in this target is the real, unmodified source file,
// symlinked from Source/ — the point of the target is that those compile
// against the shim without being touched.
//
// Both of these are text infrastructure. The engine behind them is real
// (Android/Text: HarfBuzz and FreeType, with the glyph atlas) and so is the
// CoreText surface above them, which is why TextHelpers.swift compiles here
// unchanged. These two stay stubs because they need the language pick, which
// belongs to the localisation ring, and because wiring them would make this
// package need Text — and with it a cmake run — for everyone building the
// game's sources. Android/Probe is where the two meet.

enum FontRegistry {
    /// Real one registers the bundled Chiron GoRound TC faces with CoreText.
    /// On Android it becomes `TextEngine.install(fontsAt:)`, which registers
    /// the same files from Assets/Fonts — including the variable font's
    /// named instances, which is how "ChironGoRoundTC-Black" resolves.
    static func registerChiron() {}
}

enum Localization {
    struct Script {
        /// Real one returns KoHo for Thai and Chiron for everything else.
        /// Both faces are registered by then; all this needs is the language
        /// pick, so it lands with the localisation port.
        func scriptFontName(_ weight: UIFont.Weight) -> String? { nil }

        /// Real one picks per script, out of the same DesignSystem
        /// constants — which are compiled here, so this is the real value
        /// for every language but the four with taller scripts.
        var lineHeightRatio: CGFloat { DesignSystem.textLineHeight }
    }

    static let current = Script()
}

// SpriteHelpers.swift's own two entry points.
//
// The real file is not linked in here because its texture cache reaches
// straight into the renderer — SceneLighting, LiveBackdrops, RigMeshNode,
// ArtSlices. That is the next ring of the port (asset loading and the GL
// texture cache), not this slice, so these stand in for it.

func sprite(_ imageName: String, size: CGSize? = nil) -> SKSpriteNode {
    let texture = SKTexture(imageNamed: imageName)
    return SKSpriteNode(texture: texture, size: size ?? texture.size())
}

func tinted(_ imageName: String, _ color: UIColor, size: CGSize? = nil) -> SKSpriteNode {
    let node = sprite(imageName, size: size)
    node.color = color
    node.colorBlendFactor = 1
    return node
}

// DesignSystem is a flat table of constants, but three of its ~3,900 lines
// name types that live in the renderer or the rules. Rather than drag those
// trees in — BoardGroundingArt, CircuitBoardNode, Timeline and everything
// they reach — this slice declares just the shapes those constants need.
// All three are ordinary portable Swift; they come in with their own rings.

struct BoardGrounding: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let shadow = BoardGrounding(rawValue: 1 << 0)
    static let light = BoardGrounding(rawValue: 1 << 1)
    static let calm = BoardGrounding(rawValue: 1 << 2)
    static let patch = BoardGrounding(rawValue: 1 << 3)
    static let tufts = BoardGrounding(rawValue: 1 << 4)
}

enum CircuitKit {
    enum Kind {
        case capacitors, battery, chip, crystal, resistor, led, fan, heatSink
    }
}

enum Timeline {
    enum Duration {
        /// Milliseconds, as the real one keeps them.
        static let step: TimeInterval = 200
    }
}
