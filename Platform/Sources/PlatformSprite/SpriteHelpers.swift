import Foundation
import SpriteKitShim

/// What a game tells the sprite helpers about its art.
public nonisolated enum SpriteArt {
    /// The art's pixels per point, when its images aren't drawn at the
    /// screen's own scale (art made for another engine's resolution): a
    /// sprite then takes its texture's pixels at this scale as its size, and
    /// `sliced` scales its caps with it. Nil: SpriteKit's own point size.
    public nonisolated(unsafe) static var scale: CGFloat?

    /// An image's 9-slice cap insets, in the art's points, given its size in
    /// them (a generated slice table, say); nil for an image that doesn't
    /// slice.
    public nonisolated(unsafe) static var capInsets: (_ imageName: String, _ size: CGSize) -> UIEdgeInsets? = { _, _ in nil }

    /// Runs `hook` every time `forgetTextures(where:)` forgets textures,
    /// with the same pick: for caches of the game's own that hold assets'
    /// textures (lit shaders holding normal maps, say).
    public static func whenForgetting(_ hook: @escaping ((String) -> Bool) -> Void) {
        TextureCache.state.withLock { $0.forgetHooks.append(hook) }
    }
}

private nonisolated enum TextureCache {
    struct State {
        var textures: [String: SKTexture] = [:]
        /// `sliced`'s textures at a scale of their own, by name and scale.
        var scaled: [String: (name: String, texture: SKTexture)] = [:]
        var forgetHooks: [((String) -> Bool) -> Void] = []
    }

    /// `txtr` runs on the main thread, loading queues and preloads alike.
    static let state = Locked(State())
}

/// Asset-backed textures are cached so every sprite of the same image shares
/// one texture (and SpriteKit can batch their draws). Safe on any thread.
public nonisolated func txtr(_ imageName: String) -> SKTexture {
    TextureCache.state.withLock { state in
        if let cached = state.textures[imageName] { return cached }
        let texture = SKTexture(imageNamed: imageName)
        texture.filteringMode = .linear
        state.textures[imageName] = texture
        return texture
    }
}

/// Forgets every cached texture, so a scene that no longer shows them lets
/// them go. Sprites keep their own; call it on the main thread, before the
/// next scene builds.
public nonisolated func clearTextureCache() {
    forgetTextures { _ in true }
}

/// Whether `txtr` already holds `imageName`.
public nonisolated func isTextureCached(_ imageName: String) -> Bool {
    TextureCache.state.withLock { $0.textures[imageName] != nil }
}

/// Forgets the cached textures `forget` picks, so they go once no sprite
/// shows them, and runs the hooks `SpriteArt.whenForgetting` registered.
/// Pick only what is off screen: asking `txtr` again for one still shown
/// makes a second copy.
public nonisolated func forgetTextures(where forget: (String) -> Bool) {
    let hooks = TextureCache.state.withLock { state in
        state.textures = state.textures.filter { !forget($0.key) }
        state.scaled = state.scaled.filter { !forget($0.value.name) }
        return state.forgetHooks
    }
    withoutActuallyEscaping(forget) { forget in
        for hook in hooks { hook(forget) }
    }
}

/// Every texture `node` and all it holds show, once each (to preload).
public func textures(in node: SKNode) -> [SKTexture] {
    var seen = Set<ObjectIdentifier>()
    var found: [SKTexture] = []
    func visit(_ node: SKNode) {
        if let texture = (node as? SKSpriteNode)?.texture, seen.insert(ObjectIdentifier(texture)).inserted {
            found.append(texture)
        }
        node.children.forEach(visit)
    }
    visit(node)
    return found
}

/// A sprite of `imageName`, at `size` or else the art's own size.
public func sprite(_ imageName: String, size: CGSize? = nil) -> SKSpriteNode {
    let texture = txtr(imageName)
    let sprite = SKSpriteNode(texture: texture)
    if let size {
        sprite.size = size
    } else if SpriteArt.scale != nil {
        sprite.size = artSize(of: texture)
    }
    return sprite
}

/// A texture's size in points: its pixels at `SpriteArt.scale`, else
/// SpriteKit's own size.
public func artSize(of texture: SKTexture) -> CGSize {
    let size = texture.size()
    guard let scale = SpriteArt.scale else { return size }
    return sz(size.width / scale, size.height / scale)
}

/// A white texture tinted to a solid colour (icons, glyphs, caps).
public func tinted(_ imageName: String, _ color: UIColor, size: CGSize? = nil) -> SKSpriteNode {
    let node = sprite(imageName, size: size)
    node.color = color
    node.colorBlendFactor = 1
    return node
}

/// A 9-slice sprite: the corners keep their size, the edges stretch along
/// their length and the middle stretches both ways, by the cap insets
/// `SpriteArt.capInsets` gives.
///
/// With art at a scale of its own (`SpriteArt.scale`), `scale` is the
/// sprite's own scale: it shows `size * scale` with its caps scaled too, at
/// a node scale of 1. SpriteKit sizes a centre rect's caps by the texture's
/// point size and mis-draws them under a node scale below 1, so the texture
/// is made at the art's points times `scale` instead.
public func sliced(_ imageName: String, size: CGSize, scale: CGFloat = 1) -> SKSpriteNode {
    guard SpriteArt.scale != nil else {
        let node = SKSpriteNode(texture: txtr(imageName))
        node.slice(imageName)
        node.size = size
        return node
    }
    let texture = slicedTexture(imageName, scale: scale)
    let node = SKSpriteNode(texture: texture, size: texture.size())
    node.slice(imageName)
    node.size = sz(size.width * scale, size.height * scale)
    return node
}

/// `imageName`'s art as a texture `scale` times its point size.
private func slicedTexture(_ imageName: String, scale: CGFloat) -> SKTexture {
    let key = "\(imageName)@\(scale)"
    if let cached = TextureCache.state.withLock({ $0.scaled[key]?.texture }) { return cached }
    guard let artScale = SpriteArt.scale, let image = UIImage(named: imageName)?.cgImage else { return txtr(imageName) }
    #if SPRITEKIT_SHIM
    let scaled = UIImage(cgImage: image, scale: artScale / scale)
    #else
    let scaled = UIImage(cgImage: image, scale: artScale / scale, orientation: .up)
    #endif
    let texture = SKTexture(image: scaled)
    texture.filteringMode = .linear
    TextureCache.state.withLock { $0.scaled[key] = (imageName, texture) }
    return texture
}

extension SKSpriteNode {
    /// 9-slices the sprite's texture, `imageName`, by its cap insets
    /// (`SpriteArt.capInsets`).
    public func slice(_ imageName: String) {
        guard let texture else { return }
        // The art's own point size, whatever scale the texture was made at.
        let full = SpriteArt.scale == nil ? texture.size() : artSize(of: txtr(imageName))
        guard let caps = SpriteArt.capInsets(imageName, full), full.width > 0, full.height > 0 else { return }
        centerRect = rect(
            caps.left / full.width,
            caps.bottom / full.height,
            (full.width - caps.left - caps.right) / full.width,
            (full.height - caps.top - caps.bottom) / full.height
        )
    }
}

/// A node that says what it covers at rest, in its own space, where its
/// accumulated frame would also count soft shadows and texture padding.
public protocol RestingBounds {
    var restingBounds: CGRect { get }
}

extension SKNode {
    /// `bounds`, in this node's space, in `node`'s space (neither may rotate;
    /// unlike `UICoordinateSpace`'s `convert`, this stays in scene units).
    public func convertRect(_ bounds: CGRect, to node: SKNode) -> CGRect {
        let start = convert(pt(bounds.minX, bounds.minY), to: node)
        let end = convert(pt(bounds.maxX, bounds.maxY), to: node)
        return rect(min(start.x, end.x), min(start.y, end.y), abs(end.x - start.x), abs(end.y - start.y))
    }

    /// `bounds`, in this node's space, as the box round its four corners in
    /// `node`'s space: unlike `convertRect`, it holds through rotation.
    public func boundingRect(_ bounds: CGRect, in node: SKNode) -> CGRect {
        let corners = [
            pt(bounds.minX, bounds.minY), pt(bounds.maxX, bounds.minY),
            pt(bounds.minX, bounds.maxY), pt(bounds.maxX, bounds.maxY),
        ].map { convert($0, to: node) }
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return bounds }
        return rect(minX, minY, maxX - minX, maxY - minY)
    }

    /// What this node covers, in `node`'s space, as it rests at its own
    /// scale of 1 (entrances grow nodes in from smaller): its
    /// `restingBounds`, or else everything it draws.
    public func restingFrame(in node: SKNode) -> CGRect {
        guard let parent else { return .null }
        if let bounds = (self as? RestingBounds)?.restingBounds {
            return parent.convertRect(bounds.offset(position), to: node)
        }
        guard xScale != 0, yScale != 0 else { return .null }
        let frame = calculateAccumulatedFrame()
        let rest = rect(
            position.x + (frame.minX - position.x) / xScale,
            position.y + (frame.minY - position.y) / yScale,
            frame.width / xScale,
            frame.height / yScale
        ).standardized
        return parent.convertRect(rest, to: node)
    }
}

/// Everything `node` draws (its accumulated frame), in `scene`'s space: the
/// box round its corners, so it holds through rotation and scale between
/// them. A node with no parent answers its own frame.
public func rectInScene(for node: SKNode, scene: SKNode) -> CGRect {
    let frame = node.calculateAccumulatedFrame()
    guard let parent = node.parent else { return frame }
    return parent.boundingRect(frame, in: scene)
}

/// `localRect`, in `node`'s space, in `scene`'s space, as the box round its
/// corners.
public func rectInScene(_ localRect: CGRect, for node: SKNode, scene: SKNode) -> CGRect {
    node.boundingRect(localRect, in: scene)
}
