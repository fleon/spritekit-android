#if SPRITEKIT_SHIM
import Foundation

/// What one frame of a scene graph flattens to: the handover between the
/// shim and the GLES 3 renderer.
///
/// Keeping this a plain value — rather than having nodes issue GL calls —
/// means the whole scene graph, the action system and the draw order are
/// testable on the host with no device, no context and no window, which is
/// how this layer can be built before the Android app shell exists.
public struct DrawList {
    public enum Command {
        case sprite(Sprite)
        case shape(Shape)
        case label(Label)
        /// Draw `contents` into an offscreen texture covering `bounds`, then
        /// composite it through `shader`.
        case effect(Effect)
        /// Draw `contents` clipped to `mask`.
        case crop(Crop)
    }

    public struct Sprite {
        public var transform: CGAffineTransform
        public var size: CGSize
        public var anchorPoint: CGPoint
        public var texture: SKTexture?
        public var textureRect: CGRect
        public var color: SKColor
        public var colorBlendFactor: CGFloat
        public var alpha: CGFloat
        public var blendMode: SKBlendMode
        public var shader: SKShader?
        public var attributeValues: [String: SKAttributeValue]
    }

    public struct Shape {
        public var transform: CGAffineTransform
        public var path: CGPath?
        public var fillColor: SKColor
        public var strokeColor: SKColor
        public var lineWidth: CGFloat
        public var lineCap: CGLineCap
        public var lineJoin: CGLineJoin
        public var alpha: CGFloat
    }

    public struct Label {
        public var transform: CGAffineTransform
        public var text: String
        public var fontName: String?
        public var fontSize: CGFloat
        public var color: SKColor
        public var horizontal: SKLabelHorizontalAlignmentMode
        public var vertical: SKLabelVerticalAlignmentMode
        public var alpha: CGFloat
        /// The lines as the node broke and placed them, so the renderer
        /// draws exactly what was measured. Nil when no `TextProvider` is
        /// registered, which is the renderer's cue that there is nothing to
        /// draw rather than a reason to measure the string itself.
        public var layout: TextLayout?
    }

    public struct Effect {
        public var bounds: CGRect
        public var transform: CGAffineTransform
        public var shader: SKShader?
        public var alpha: CGFloat
        public var contents: DrawList
    }

    public struct Crop {
        public var transform: CGAffineTransform
        public var mask: DrawList
        public var contents: DrawList
    }

    public var commands: [Command] = []

    public init() {}

    /// Flattens a subtree in SpriteKit's draw order.
    ///
    /// SpriteKit (with the default `ignoresSiblingOrder`) orders purely by
    /// accumulated zPosition and leaves ties nondeterministic — which is why
    /// the game sets explicit zPosition for overlapping siblings. This sorts
    /// stably, so ties fall in tree order: strictly more deterministic than
    /// SpriteKit, and never less.
    public init(scene: SKNode) {
        commands = DrawList.flatten(scene, parentTransform: .identity, parentAlpha: 1, parentZ: 0)
    }

    private static func flatten(
        _ node: SKNode,
        parentTransform: CGAffineTransform,
        parentAlpha: CGFloat,
        parentZ: CGFloat
    ) -> [Command] {
        guard !node.isHidden, node.alpha > 0 else { return [] }

        let transform = node.localTransform.concatenating(parentTransform)
        let alpha = node.alpha * parentAlpha
        let z = parentZ + node.zPosition

        // An effect or crop node composites its whole subtree, so it is one
        // command at its own depth rather than a set of siblings.
        if let effect = node as? SKEffectNode, effect.shouldEnableEffects {
            let contents = children(of: node, transform: .identity, alpha: 1, z: 0)
            return [(z, Command.effect(Effect(
                bounds: effect.effectBounds,
                transform: transform,
                shader: effect.shader,
                alpha: alpha,
                contents: wrap(contents)
            )))].map(\.1)
        }

        if let crop = node as? SKCropNode {
            // The mask node itself draws the shape, so flatten it, not just
            // its children — a solid sprite mask has none.
            let mask = crop.maskNode.map {
                flatten($0, parentTransform: .identity, parentAlpha: 1, parentZ: 0)
            } ?? []
            let contents = children(of: node, transform: .identity, alpha: 1, z: 0)
            return [Command.crop(Crop(
                transform: transform,
                mask: wrap(mask),
                contents: wrap(contents)
            ))]
        }

        var entries: [(CGFloat, Command)] = []

        if let sprite = node as? SKSpriteNode, sprite.size != .zero {
            entries.append((z, .sprite(Sprite(
                transform: transform,
                size: sprite.size,
                anchorPoint: sprite.anchorPoint,
                texture: sprite.texture,
                textureRect: sprite.texture?.textureRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                color: sprite.color,
                colorBlendFactor: sprite.colorBlendFactor,
                alpha: alpha,
                blendMode: sprite.blendMode,
                shader: sprite.shader,
                attributeValues: sprite.attributeValues
            ))))
        } else if let shape = node as? SKShapeNode {
            entries.append((z, .shape(Shape(
                transform: transform,
                path: shape.path,
                fillColor: shape.fillColor,
                strokeColor: shape.strokeColor,
                lineWidth: shape.lineWidth,
                lineCap: shape.lineCap,
                lineJoin: shape.lineJoin,
                alpha: alpha
            ))))
        } else if let label = node as? SKLabelNode, let text = label.text, !text.isEmpty {
            entries.append((z, .label(Label(
                transform: transform,
                text: text,
                fontName: label.fontName,
                fontSize: label.fontSize,
                color: label.fontColor ?? .white,
                horizontal: label.horizontalAlignmentMode,
                vertical: label.verticalAlignmentMode,
                alpha: alpha,
                layout: label.layout
            ))))
        }

        for child in node.children {
            let sub = flatten(child, parentTransform: transform, parentAlpha: alpha, parentZ: z)
            let childZ = z + child.zPosition
            entries.append(contentsOf: sub.map { (childZ, $0) })
        }

        return entries
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.0 == rhs.element.0
                    ? lhs.offset < rhs.offset       // stable: ties keep tree order
                    : lhs.element.0 < rhs.element.0
            }
            .map(\.element.1)
    }

    private static func children(
        of node: SKNode,
        transform: CGAffineTransform,
        alpha: CGFloat,
        z: CGFloat
    ) -> [Command] {
        node.children.flatMap {
            flatten($0, parentTransform: transform, parentAlpha: alpha, parentZ: z)
        }
    }

    private static func wrap(_ commands: [Command]) -> DrawList {
        var list = DrawList()
        list.commands = commands
        return list
    }

    /// Sprite commands anywhere in the list, nested ones included.
    public var spriteCount: Int {
        commands.reduce(0) { total, command in
            switch command {
            case .sprite: return total + 1
            case .shape, .label: return total
            case let .effect(effect): return total + effect.contents.spriteCount
            case let .crop(crop): return total + crop.contents.spriteCount
            }
        }
    }
}

#endif
