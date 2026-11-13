#if SPRITEKIT_SHIM
import Foundation

public enum SKLabelHorizontalAlignmentMode: Int, Sendable {
    case center, left, right
}

public enum SKLabelVerticalAlignmentMode: Int, Sendable {
    case baseline, center, top, bottom
}

/// Text.
///
/// This is the one part of the layer with no shortcut. The game ships 19
/// languages, and Thai needs reordering and KoHo's shaping; CJK needs the
/// full font. Android has no CoreText, and FreeType alone only rasterises
/// glyphs — it does not shape runs. The renderer behind this must be
/// HarfBuzz for shaping plus FreeType for rasterising, feeding a glyph
/// atlas, with the game's own `wrappedLines` line breaking on top.
///
/// Until that lands, this measures and lays out nothing: it holds the state
/// the game sets so the rest of the layer compiles and runs, and reports its
/// frame as empty. Everything that positions text will look wrong, which is
/// the honest signal that this is unfinished rather than subtly incorrect.
open class SKLabelNode: SKNode {
    open var text: String?
    open var fontName: String?
    open var fontSize: CGFloat = 32
    open var fontColor: SKColor? = .white
    open var horizontalAlignmentMode: SKLabelHorizontalAlignmentMode = .center
    open var verticalAlignmentMode: SKLabelVerticalAlignmentMode = .baseline
    open var numberOfLines: Int = 1
    open var preferredMaxLayoutWidth: CGFloat = 0
    open var lineBreakMode: Int = 0
    open var blendMode: SKBlendMode = .alpha

    public override init() {
        super.init()
    }

    public init(fontNamed name: String?) {
        fontName = name
        super.init()
    }

    public convenience init(text: String?) {
        self.init()
        self.text = text
    }

    /// Zero until shaping is in. See the note above.
    open override var contentFrame: CGRect { .zero }
}

/// Vector shapes — buttons, panels, meters and the focus rings.
///
/// 16 uses directly, but `SurfaceTexture` (7 CGContext sites) draws most
/// chunky surfaces, so the renderer needs a 2D path rasteriser either way.
/// The shim records the path; filling and stroking it is the renderer's job.
open class SKShapeNode: SKNode {
    open var path: CGPath?
    open var lineCap: CGLineCap = .butt
    open var lineJoin: CGLineJoin = .miter
    open var fillColor: SKColor = .clear
    open var strokeColor: SKColor = .white
    open var lineWidth: CGFloat = 1
    open var glowWidth: CGFloat = 0
    open var isAntialiased: Bool = true
    open var blendMode: SKBlendMode = .alpha
    open var fillTexture: SKTexture?
    open var fillShader: SKShader?

    public override init() {
        super.init()
    }

    // The game builds shapes through its own `shape(_:)` helper and assigns
    // `path`, so no convenience initialisers are needed here.

    open override var contentFrame: CGRect {
        guard let path else { return .zero }
        return path.boundingBox.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }
}

#endif
