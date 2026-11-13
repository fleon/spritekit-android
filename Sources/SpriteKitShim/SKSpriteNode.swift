#if SPRITEKIT_SHIM
import Foundation

/// A textured or solid-colour quad — 378 uses in the game, and with SKNode the
/// bulk of what the board draws.
open class SKSpriteNode: SKNode {
    open var texture: SKTexture?
    open var color: SKColor
    open var colorBlendFactor: CGFloat = 0
    open var blendMode: SKBlendMode = .alpha
    open var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    open var shader: SKShader?
    open var size: CGSize

    /// Per-node shader attribute values (SKAttribute), keyed by name.
    open var attributeValues: [String: SKAttributeValue] = [:]

    public init(texture: SKTexture?, size: CGSize) {
        self.texture = texture
        self.size = size
        color = .clear
        super.init()
    }

    public convenience init(texture: SKTexture?) {
        let size = texture?.size() ?? .zero
        self.init(texture: texture, size: size)
    }

    public convenience init(texture: SKTexture?, color: SKColor, size: CGSize) {
        self.init(texture: texture, size: size)
        self.color = color
    }

    public init(color: SKColor, size: CGSize) {
        texture = nil
        self.color = color
        self.size = size
        colorBlendFactor = 1
        super.init()
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
            x: -size.width * anchorPoint.x,
            y: -size.height * anchorPoint.y,
            width: size.width,
            height: size.height
        )
    }
}

#endif
