import Macros
import SpriteKit

// The port's own `BandedLayerNode`, standing where `Source/Common/Components/
// BandedLayerNode.swift` does: the game's, line for line, but for a band
// count `debug.switchlings.bands` can change for measuring (`bandCount`).
// Both draw every layer in 4 bands (`DesignSystem.bandedLayerBands`). Keep
// the two in step.

/// A full-screen shader too costly to run over every pixel every frame on a
/// big screen (Castle's sea of clouds, Sky's night, Reef's water, the forest
/// floor and its beams; behind gameplay Ruins' water, Reef's rays and the
/// caustic light over its board): it draws in bands across its frame,
/// each cached in an effect node that rasterizes, and redraws one band a
/// frame, in turn, so a frame pays for a fraction of the shader. What these
/// layers show drifts slowly, so a band a few frames old never shows, nor do
/// the seams between bands; anything quick (Sky's shooting star) stays out
/// of them.
@NSCodingUnsupported
final class BandedLayerNode: SKNode {
    private enum ActionKey {
        static let redraw = "banded_layer.redraw"
    }

    private var bands: [SKEffectNode] = []
    private var nextBand = 0
    /// The uniforms that change as the layer plays, and each band's own
    /// copies of them, brought up to date only as it redraws: a uniform
    /// that changes drops every cache that reads it.
    private var live: [SKUniform] = []
    private var copies: [[SKUniform]] = []
    /// No band redraws until then (`hold`).
    private var heldUntil: TimeInterval = 0
    /// Every layer draws whole and uncached, every frame: for renders that
    /// don't count a frame's cost (the header video's film), where bands a
    /// few frames apart would flicker.
    nonisolated(unsafe) static var drawsWhole = false
    /// The bands every layer draws in here, whatever `count` it's handed.
    nonisolated(unsafe) static var bandCount = DesignSystem.bandedLayerBands

    override init() {
        super.init()
    }

    /// Draws `source`, a shader written for one sprite over `frame` that
    /// finds its place there from `v_tex_coord`, with `uniforms` and the
    /// `live` ones it changes as it plays; `texture`, if given, is what its
    /// `SKDefaultShading()` reads. A band's cache renders at the scene's
    /// density, so its content is magnified inside it by `pointsPerUnit`
    /// (the view's points a scene unit) and shrunk back; a view drawing
    /// fewer pixels than its screen's (the graphics setting's render scale,
    /// `RenderScaleController`) renders its bands as few. More `count`
    /// bands redraw less of the layer each frame, each less often.
    func draw(source: String, uniforms: [SKUniform], live: [SKUniform] = [], texture: SKTexture? = nil, frame: CGRect, pointsPerUnit: CGFloat,
              count: Int = DesignSystem.bandedLayerBands) {
        removeAllChildren()
        bands = []
        nextBand = 0
        self.live = live
        copies = []
        guard !frame.isEmpty else { return }
        var source = source
        var uniforms = uniforms
        if let texture {
            source = source.replacingOccurrences(of: "SKDefaultShading()", with: "texture2D(u_band_texture, v_tex_coord)")
            uniforms.append(SKUniform(name: "u_band_texture", texture: texture))
        }
        // Each band's own coordinates, carried over to the whole frame's.
        source = source.replacingOccurrences(of: "v_tex_coord", with: "(u_band.xy + v_tex_coord * u_band.zw)")
        if Self.drawsWhole {
            let sprite = SKSpriteNode(color: .white, size: frame.size)
            sprite.shader = SKShader(source: source, uniforms: uniforms + live + [SKUniform(name: "u_band", vectorFloat4: SIMD4(0, 0, 1, 1))])
            sprite.position = pt(frame.midX, frame.midY)
            addChild(sprite)
            return
        }
        let count = Self.bandCount
        let magnified = max(pointsPerUnit, 1)
        for index in 0..<count {
            let share = 1 / CGFloat(count)
            // Each band reaches a little into its neighbours, so where the
            // view draws below the screen's pixels and is scaled up, a
            // band's soft edge lies over the next one's solid middle, never
            // over the backdrop as a seam.
            let overlap = DesignSystem.bandedLayerOverlap
            let band = rect(frame.minX, frame.minY + CGFloat(index) * share * frame.height - overlap, frame.width, share * frame.height + 2 * overlap)
            let unit = rect(0, (band.minY - frame.minY) / frame.height, 1, band.height / frame.height)
            let sprite = SKSpriteNode(color: .white, size: band.size)
            let own = live.map(Self.copy)
            copies.append(own)
            sprite.shader = SKShader(source: source, uniforms: uniforms + own + [
                SKUniform(name: "u_band", vectorFloat4: SIMD4(Float(unit.minX), Float(unit.minY), Float(unit.width), Float(unit.height))),
            ])
            sprite.position = pt(band.midX * magnified, band.midY * magnified)
            sprite.setScale(magnified)
            let cache = SKEffectNode()
            cache.shouldRasterize = true
            cache.setScale(1 / magnified)
            cache.addChild(sprite)
            addChild(cache)
            bands.append(cache)
        }
        run(.repeatForever(.customAction(withDuration: 1) { node, _ in
            (node as? BandedLayerNode)?.redrawNext()
        }), withKey: ActionKey.redraw)
    }

    /// Redraws no band for `bandedLayerHold`: while the layer slides past
    /// (the world list's pages), a band a few frames old never shows either,
    /// and two backdrops draw at once.
    func hold() {
        heldUntil = CACurrentMediaTime() + DesignSystem.bandedLayerHold
    }

    /// Drops the bands' cache so the next band in turn draws again.
    private func redrawNext() {
        guard !bands.isEmpty, CACurrentMediaTime() >= heldUntil else { return }
        let index = nextBand % bands.count
        nextBand += 1
        for (copy, uniform) in zip(copies[index], live) { Self.update(copy, from: uniform) }
        bands[index].shouldRasterize = false
        bands[index].shouldRasterize = true
    }

    private static func copy(_ uniform: SKUniform) -> SKUniform {
        let name = uniform.name
        return switch uniform.uniformType {
        case .float: SKUniform(name: name, float: uniform.floatValue)
        case .floatVector2: SKUniform(name: name, vectorFloat2: uniform.vectorFloat2Value)
        case .floatVector3: SKUniform(name: name, vectorFloat3: uniform.vectorFloat3Value)
        case .floatVector4: SKUniform(name: name, vectorFloat4: uniform.vectorFloat4Value)
        case .floatMatrix2: SKUniform(name: name, matrixFloat2x2: uniform.matrixFloat2x2Value)
        case .floatMatrix3: SKUniform(name: name, matrixFloat3x3: uniform.matrixFloat3x3Value)
        case .floatMatrix4: SKUniform(name: name, matrixFloat4x4: uniform.matrixFloat4x4Value)
        case .texture: SKUniform(name: name, texture: uniform.textureValue)
        default: SKUniform(name: name)
        }
    }

    private static func update(_ copy: SKUniform, from uniform: SKUniform) {
        switch uniform.uniformType {
        case .float: copy.floatValue = uniform.floatValue
        case .floatVector2: copy.vectorFloat2Value = uniform.vectorFloat2Value
        case .floatVector3: copy.vectorFloat3Value = uniform.vectorFloat3Value
        case .floatVector4: copy.vectorFloat4Value = uniform.vectorFloat4Value
        case .floatMatrix2: copy.matrixFloat2x2Value = uniform.matrixFloat2x2Value
        case .floatMatrix3: copy.matrixFloat3x3Value = uniform.matrixFloat3x3Value
        case .floatMatrix4: copy.matrixFloat4x4Value = uniform.matrixFloat4x4Value
        case .texture: copy.textureValue = uniform.textureValue
        case .none: break
        @unknown default: break
        }
    }
}
