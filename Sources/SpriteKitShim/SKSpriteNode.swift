#if SPRITEKIT_SHIM
import Foundation

/// A textured or solid-colour quad — with SKNode the bulk of what a scene
/// draws.
open class SKSpriteNode: SKNode {
    open var texture: SKTexture?
    open var color: SKColor
    open var colorBlendFactor: CGFloat = 0
    open var blendMode: SKBlendMode = .alpha
    open var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    open var shader: SKShader?
    /// Carried for a game whose lighting reads normals from its own shaders'
    /// uniforms; SpriteKit's own lighting, which this feeds, isn't
    /// implemented (there is no `SKLightNode`).
    open var normalTexture: SKTexture?
    /// The size before the node's scale: what the renderer draws, the
    /// node's transform scaling it.
    var unscaledSize: CGSize

    /// SpriteKit's size reads scaled (by the scale's magnitude, so a flip
    /// keeps it positive) and is set through the scale: what's kept is the
    /// size before it, or the size as given along an axis scaled to 0.
    open var size: CGSize {
        get { CGSize(width: unscaledSize.width * abs(xScale), height: unscaledSize.height * abs(yScale)) }
        set {
            unscaledSize = CGSize(width: xScale != 0 ? newValue.width / abs(xScale) : newValue.width,
                                  height: yScale != 0 ? newValue.height / abs(yScale) : newValue.height)
        }
    }

    /// Per-node shader attribute values (SKAttribute), keyed by name.
    open var attributeValues: [String: SKAttributeValue] = [:]

    /// Bends the picture (SKWarpable, SKWarpGeometry.swift).
    open var warpGeometry: SKWarpGeometry?
    open var subdivisionLevels: Int = 2

    /// Triangles drawn instead of the quad (SKTriangleMesh.swift): the
    /// shim's own, for a skeletal rig's meshes.
    open var triangleMesh: SKTriangleMesh?

    /// Backs `centerRect` (see NineSlice.swift), which 9-slices the texture.
    var sliceCenterRect = NineSlice.whole

    /// SpriteKit's designated initialiser; the others are convenience ones,
    /// so a subclass calls this one.
    public init(texture: SKTexture?, color: SKColor, size: CGSize) {
        self.texture = texture
        self.color = color
        unscaledSize = size
        super.init()
    }

    public convenience init(texture: SKTexture?, size: CGSize) {
        self.init(texture: texture, color: .white, size: size)
    }

    public convenience init(texture: SKTexture?) {
        let size = texture?.size() ?? .zero
        self.init(texture: texture, size: size)
    }

    public convenience init(color: SKColor, size: CGSize) {
        self.init(texture: nil, color: color, size: size)
        colorBlendFactor = 1
    }

    /// An empty sprite, as SpriteKit's `SKSpriteNode()`: no texture, clear,
    /// zero-sized, to fill in later.
    public override convenience init() {
        self.init(texture: nil, size: .zero)
    }

    public convenience init(imageNamed name: String) {
        let texture = SKTexture(imageNamed: name)
        self.init(texture: texture, size: texture.size())
    }

    open func setValue(_ value: SKAttributeValue, forAttribute key: String) {
        attributeValues[key] = value
    }

    open func value(forAttributeNamed key: String) -> SKAttributeValue? {
        attributeValues[key]
    }

    /// The quad in the node's own coordinates, placed by its anchor point.
    open override var contentFrame: CGRect {
        CGRect(
            x: -unscaledSize.width * anchorPoint.x,
            y: -unscaledSize.height * anchorPoint.y,
            width: unscaledSize.width,
            height: unscaledSize.height
        )
    }
}

#endif
