import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// How far round a `LoadingSpinner`'s arc reaches through each period.
public nonisolated enum LoadingSpinnerSweep {
    /// The angle `progress` (0 to 1) through a period: out to the whole ring
    /// by halfway, at a steady pace, and back to nothing at the same.
    public static func angle(at progress: CGFloat) -> CGFloat {
        let progress = progress.clamp(0, 1)
        return progress < 0.5
            ? (progress * 2).lerp(0, .pi * 2)
            : ((progress - 0.5) * 2).lerp(.pi * 2, 0)
    }
}

#if canImport(UIKit) || !canImport(Darwin)

/// A loading spinner in any colour: an arc of a ring, with round ends, drawn
/// from the ring's right, that reaches all the way round and draws back to
/// nothing every `period`, while it turns clockwise twice as it grows and
/// once as it shrinks. It fades in first.
///
/// A shader draws the arc on one sprite, swept as far as it reaches, so it
/// costs no path or texture per frame. Safe to make off the main thread
/// (in a scene's `load()`).
public final class LoadingSpinner: SKNode {
    /// The ring's radius, to the middle of its line, in points.
    public let radius: CGFloat
    /// How thick its line is, in points.
    public let thickness: CGFloat

    /// The arc's colour; its alpha is the arc's.
    public var color: UIColor {
        didSet { shading.tint(color) }
    }

    private let arc: SKSpriteNode
    private let shading: Shading

    /// A spinner `radius` round (to the middle of its line) and `thickness`
    /// thick, that reaches round and back every `period` and fades in over
    /// `fadeIn` (0 shows it at once).
    public init(color: UIColor = .white, radius: CGFloat = 14, thickness: CGFloat = 4, period: TimeInterval = 4, fadeIn: TimeInterval = 0.2) {
        self.radius = radius
        self.thickness = thickness
        self.color = color
        let reach = radius + thickness / 2 + ShapeSprite.room
        shading = Self.take()
        shading.shape(radius: radius, thickness: thickness, reach: reach)
        shading.tint(color)
        arc = SKSpriteNode(color: .white, size: sz(reach * 2, reach * 2))
        super.init()
        arc.shader = shading.shader
        addChild(arc)
        let spin = SKAction.repeatForever(.group([
            .customAction(withDuration: period) { [weak self] _, elapsed in
                self?.reach(LoadingSpinnerSweep.angle(at: elapsed / CGFloat(period)))
            },
            .sequence([
                .rotate(byAngle: -.pi * 4, duration: period / 2),
                .rotate(byAngle: -.pi * 2, duration: period / 2),
            ]),
        ]))
        if fadeIn > 0 {
            arc.alpha = 0
            arc.run(.sequence([.fadeIn(withDuration: fadeIn), spin]))
        } else {
            arc.run(spin)
        }
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Self.give(shading)
    }

    /// Shows the arc reaching `angle` round from its start (0 hides it,
    /// 2π closes the ring).
    public func reach(_ angle: CGFloat) {
        shading.sweep.floatValue = Float(angle)
    }

    // MARK: Shading

    /// A spinner's shader and the uniforms it sets, every one its own.
    private final class Shading: @unchecked Sendable {
        let sweep = SKUniform(name: "u_sweep", float: 0)
        let color = SKUniform(name: "u_color", vectorFloat4: SIMD4(1, 1, 1, 1))
        let reach = SKUniform(name: "u_reach", float: 1)
        let radius = SKUniform(name: "u_radius", float: 1)
        let half = SKUniform(name: "u_half", float: 1)
        let pixel = SKUniform(name: "u_pixel", float: 1)
        lazy var shader = SKShader(source: LoadingSpinner.source, uniforms: [sweep, color, reach, radius, half, pixel])

        func shape(radius: CGFloat, thickness: CGFloat, reach: CGFloat) {
            sweep.floatValue = 0
            self.reach.floatValue = Float(reach)
            self.radius.floatValue = Float(radius)
            // Half the line a shape node's stroke would show
            // (`ShapeSprite.strokeWidth`), its edge over a pixel.
            half.floatValue = Float(ShapeSprite.strokeWidth(thickness) / 2)
            pixel.floatValue = Float(1 / DrawnTexture.renderScale)
        }

        func tint(_ tint: UIColor) {
            var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
            tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            color.vectorFloat4Value = SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        }
    }

    /// Shaders no spinner shows any more, kept so the next spinner needn't
    /// compile its own (SpriteKit compiles each shader as it first draws).
    private static let spare = Locked<[Shading]>([])

    private static func take() -> Shading {
        spare.withLock { $0.popLast() } ?? Shading()
    }

    private static func give(_ shading: Shading) {
        spare.withLock { $0.append(shading) }
    }

    /// The arc swept anticlockwise (y up) from the ring's right, as far as
    /// `u_sweep`, its ends round: the distance to it, antialiased over a pixel.
    private static let source = """
    void main() {
        vec2 p = (v_tex_coord - 0.5) * 2.0 * u_reach;
        float angle = atan(p.y, p.x);
        if (angle < 0.0) { angle += 6.28318531; }
        float d;
        if (angle <= u_sweep) {
            d = abs(length(p) - u_radius);
        } else {
            vec2 end = u_radius * vec2(cos(u_sweep), sin(u_sweep));
            d = min(distance(p, vec2(u_radius, 0.0)), distance(p, end));
        }
        float cover = clamp((u_half - d) / u_pixel + 0.5, 0.0, 1.0) * u_color.a;
        gl_FragColor = vec4(u_color.rgb * cover, cover) * v_color_mix.a;
    }
    """
}

#endif
