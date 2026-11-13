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

    /// Flattens a subtree in SpriteKit's draw order, as the game's view sets
    /// it: `ignoresSiblingOrder = true`.
    ///
    /// That orders **every** node in the scene by its accumulated zPosition,
    /// globally — a grandchild can draw between two of a cousin's
    /// descendants. The board depends on it: kerbs live in `BoardFrameNode`
    /// and tiles in the grid layer, both at z 0, and only their own
    /// row-based z (`BoardMetrics.z(row:_:)`) puts a front kerb over the tiles
    /// behind it. Sorting each subtree as a block would draw every kerb under
    /// every tile.
    ///
    /// Ties are nondeterministic in SpriteKit, which is why the game sets
    /// explicit z for overlapping siblings. This sorts stably, so ties fall
    /// in tree order: strictly more deterministic than SpriteKit, never less.
    ///
    /// Effect and crop nodes are the exception, as they are in SpriteKit:
    /// each composites its subtree as one picture, so it is one command at
    /// its own depth, with its contents ordered the same way inside it.
    public init(scene: SKNode) {
        commands = DrawList.ordered(
            DrawList.collect(scene, parentTransform: .identity, parentAlpha: 1, parentZ: 0)
        )
    }

    /// Stable sort by accumulated z: ties keep tree order.
    private static func ordered(_ entries: [(CGFloat, Command)]) -> [Command] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.0 == rhs.element.0
                    ? lhs.offset < rhs.offset
                    : lhs.element.0 < rhs.element.0
            }
            .map(\.element.1)
    }

    /// Every command under `node`, each with its **own** accumulated z, in
    /// tree order and unsorted — sorting happens once, over the whole list.
    private static func collect(
        _ node: SKNode,
        parentTransform: CGAffineTransform,
        parentAlpha: CGFloat,
        parentZ: CGFloat
    ) -> [(CGFloat, Command)] {
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
                contents: wrap(ordered(contents))
            )))]
        }

        if let crop = node as? SKCropNode {
            // The mask node itself draws the shape, so collect it, not just
            // its children — a solid sprite mask has none.
            let mask = crop.maskNode.map {
                collect($0, parentTransform: .identity, parentAlpha: 1, parentZ: 0)
            } ?? []
            let contents = children(of: node, transform: .identity, alpha: 1, z: 0)
            return [(z, Command.crop(Crop(
                transform: transform,
                mask: wrap(ordered(mask)),
                contents: wrap(ordered(contents))
            )))]
        }

        var entries: [(CGFloat, Command)] = []

        if let sprite = node as? SKSpriteNode, sprite.size != .zero {
            // A 9-sliced sprite becomes nine ordinary sprite commands, each
            // with its own frame and sub-rect, so corners keep their size
            // while the edges and middle stretch (see NineSlice.swift).
            for piece in slices(of: sprite) {
                entries.append((z, .sprite(Sprite(
                    transform: transform,
                    size: piece.size,
                    anchorPoint: piece.anchorPoint,
                    texture: sprite.texture,
                    textureRect: piece.textureRect,
                    color: sprite.color,
                    colorBlendFactor: sprite.colorBlendFactor,
                    alpha: alpha,
                    blendMode: sprite.blendMode,
                    shader: sprite.shader,
                    attributeValues: sprite.attributeValues
                ))))
            }
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

        // Each descendant keeps its own accumulated z. Re-keying a whole
        // subtree by the child's z here is what used to keep it in one block.
        for child in node.children {
            entries.append(contentsOf: collect(
                child, parentTransform: transform, parentAlpha: alpha, parentZ: z
            ))
        }
        return entries
    }

    /// One sprite's quads: just itself, or the nine a sliced one draws as.
    /// Each carries the anchor point that puts its own frame where the whole
    /// sprite would have put that part of itself.
    private static func slices(
        of sprite: SKSpriteNode
    ) -> [(size: CGSize, anchorPoint: CGPoint, textureRect: CGRect)] {
        let textureRect = sprite.texture?.textureRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard sprite.isSliced, let art = sprite.texture?.size(), art.width > 0, art.height > 0 else {
            return [(sprite.size, sprite.anchorPoint, textureRect)]
        }
        let frame = sprite.contentFrame
        let patches = NineSlice.patches(frame: frame, textureSize: art, center: sprite.centerRect)
        guard patches.count > 1 else { return [(sprite.size, sprite.anchorPoint, textureRect)] }
        return patches.map { patch in
            // The transform is the node's, so a patch is placed by giving it
            // an anchor point that lands its own rect where the patch sits.
            (
                patch.frame.size,
                CGPoint(
                    x: patch.frame.width == 0 ? 0 : -patch.frame.minX / patch.frame.width,
                    y: patch.frame.height == 0 ? 0 : -patch.frame.minY / patch.frame.height
                ),
                NineSlice.within(textureRect, patch.unit)
            )
        }
    }

    private static func children(
        of node: SKNode,
        transform: CGAffineTransform,
        alpha: CGFloat,
        z: CGFloat
    ) -> [(CGFloat, Command)] {
        node.children.flatMap {
            collect($0, parentTransform: transform, parentAlpha: alpha, parentZ: z)
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
