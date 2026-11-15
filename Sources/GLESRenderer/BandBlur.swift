import Foundation
import SpriteKitShim

/// The live edge blur (`EdgeShade.Blur`) without its full-screen pass.
///
/// SpriteKit draws the whole backdrop through an effect node: into a texture
/// the size of the backdrop, overscan and all, then that texture onto the
/// screen through the blur shader, which blurs only the bands behind the
/// round buttons and passes every other pixel straight through. On a tiler
/// that is a full-screen store and a full-screen read every frame for the
/// sake of two strips.
///
/// This plans the same picture another way: the backdrop drawn straight
/// into the target, scissored to the pixels outside the bands, and each band
/// drawn into a texture of its own just big enough for the blur's taps,
/// then onto its pixels through the same shader. The strips sit on the
/// target's own pixel grid, so a pixel the shader passes through comes out
/// exactly as drawing it in place would.
///
/// Only the shader's uniforms are read, so the band follows the buttons
/// wherever the game puts them. Anything this can't plan exactly comes back
/// nil, and the renderer draws the effect node as before.
public struct BandBlurPlan: Equatable {
    /// A rectangle of target pixels, counted from the bottom left as GL
    /// counts them, `x1` and `y1` exclusive.
    public struct PixelRect: Equatable {
        public var x0: Int
        public var y0: Int
        public var x1: Int
        public var y1: Int

        public init(x0: Int, y0: Int, x1: Int, y1: Int) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }

        public var width: Int { max(0, x1 - x0) }
        public var height: Int { max(0, y1 - y0) }
        public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
        public var area: Int { width * height }

        public func intersection(_ other: PixelRect) -> PixelRect {
            PixelRect(x0: max(x0, other.x0), y0: max(y0, other.y0), x1: min(x1, other.x1), y1: min(y1, other.y1))
        }

        public func insetBy(dx: Int, dy: Int) -> PixelRect {
            PixelRect(x0: x0 + dx, y0: y0 + dy, x1: x1 - dx, y1: y1 - dy)
        }

        public func contains(_ other: PixelRect) -> Bool {
            other.isEmpty || (x0 <= other.x0 && y0 <= other.y0 && x1 >= other.x1 && y1 >= other.y1)
        }
    }

    /// The blur shader's uniforms, as the game last set them.
    public struct Uniforms: Equatable {
        /// Where the screen's top-left pixel lies in the scene, and how many
        /// scene points a pixel spans (`u_screen`).
        public var screen: SIMD4<Float>
        /// Each edge's inward normal, offset and reach (`u_top`, `u_bottom`).
        public var top: SIMD4<Float>
        public var bottom: SIMD4<Float>
        /// How far the effect texture's coordinates run per scene point.
        public var span: SIMD2<Float>
        /// What shows, in the scene: bottom left, then top right.
        public var crop: SIMD4<Float>
        public var fade: Float
        public var blur: Float

        public init(
            screen: SIMD4<Float>, top: SIMD4<Float>, bottom: SIMD4<Float>,
            span: SIMD2<Float>, crop: SIMD4<Float>, fade: Float, blur: Float
        ) {
            self.screen = screen
            self.top = top
            self.bottom = bottom
            self.span = span
            self.crop = crop
            self.fade = fade
            self.blur = blur
        }

        /// The uniform names that make a shader the edge blur: its own,
        /// which no other shader in the game declares together.
        public static let names: Set<String> = ["u_screen", "u_top", "u_bottom", "u_span", "u_crop", "u_fade", "u_blur", "u_ramp"]

        /// `shader`'s values, if it is the edge blur.
        public init?(_ shader: SKShader) {
            var screen: SIMD4<Float>?, top: SIMD4<Float>?, bottom: SIMD4<Float>?
            var span: SIMD2<Float>?, crop: SIMD4<Float>?, fade: Float?, blur: Float?
            var ramp = false
            for uniform in shader.uniforms {
                switch (uniform.name, uniform.value) {
                case let ("u_screen", .vector4(v)): screen = v
                case let ("u_top", .vector4(v)): top = v
                case let ("u_bottom", .vector4(v)): bottom = v
                case let ("u_span", .vector2(v)): span = v
                case let ("u_crop", .vector4(v)): crop = v
                case let ("u_fade", .float(v)): fade = Float(v)
                case let ("u_blur", .float(v)): blur = Float(v)
                case ("u_ramp", .float): ramp = true
                default: break
                }
            }
            guard ramp, let screen, let top, let bottom, let span, let crop, let fade, let blur else { return nil }
            self.init(screen: screen, top: top, bottom: bottom, span: span, crop: crop, fade: fade, blur: blur)
        }
    }

    /// One band: the pixels it covers, the strip of pixels drawn for it (the
    /// band and as far round it as the blur's taps reach), and `u_span` for
    /// the strip's texture in place of the whole backdrop's.
    public struct Strip: Equatable {
        public var band: PixelRect
        public var strip: PixelRect
        public var span: SIMD2<Float>
    }

    /// The pixels the backdrop draws straight into, outside every band.
    public var direct: PixelRect
    public var strips: [Strip]

    /// No more than this share of the target may lie in bands: past it, two
    /// strips cost about what the full-screen pass does.
    public static let largestBandShare = 0.6
    /// Texels past the blur's reach, for the bilinear taps at its rim.
    public static let tapMargin = 2

    /// Plans the blur for `uniforms` over a target `width` × `height` pixels
    /// showing `visible` (scene points), whose shaders see `fragSpace`, for
    /// an effect node covering `bounds` (its own coordinates) moved by
    /// `offset` into the target's.
    public init?(
        uniforms u: Uniforms,
        width: Int,
        height: Int,
        visible: CGRect,
        fragSpace: FragCoordSpace,
        bounds: CGRect,
        offset: CGPoint
    ) {
        guard width > 0, height > 0, visible.width > 0, visible.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let dx = Double(width) / Double(visible.width)
        let dy = Double(height) / Double(visible.height)
        // The scene point the shader finds at a pixel's centre, per axis:
        // `a + b * (i + 0.5)` (`EdgeShade.Blur`'s `p`, through `u_sk_frag`).
        let z = Double(u.screen.z)
        let xAxis = Axis(
            a: Double(u.screen.x) + z * Double(fragSpace.offsetX),
            b: z * Double(fragSpace.scaleX), count: width
        )
        let yAxis = Axis(
            a: Double(u.screen.y) - z * Double(fragSpace.offsetY),
            b: -z * Double(fragSpace.scaleY), count: height
        )
        let whole = PixelRect(x0: 0, y0: 0, x1: width, y1: height)

        // What shows: the shader drops whatever lies past `crop`.
        let (cx0, cx1) = xAxis.within(Double(u.crop.x), Double(u.crop.z))
        let (cy0, cy1) = yAxis.within(Double(u.crop.y), Double(u.crop.w))
        // The pixels the effect's composite quad covers.
        let (bx0, bx1) = Self.centres(from: (Double(bounds.minX + offset.x - visible.minX)) * dx,
                                       to: (Double(bounds.maxX + offset.x - visible.minX)) * dx)
        let (by0, by1) = Self.centres(from: (Double(bounds.minY + offset.y - visible.minY)) * dy,
                                       to: (Double(bounds.maxY + offset.y - visible.minY)) * dy)
        let covered = PixelRect(x0: bx0, y0: by0, x1: bx1, y1: by1)
        let shown = whole
            .intersection(PixelRect(x0: cx0, y0: cy0, x1: cx1, y1: cy1))
            .intersection(covered)

        // Each edge's band as pixels along one axis, from one end.
        var low: Int?
        var high: Int?
        var bandAxisIsX: Bool?
        for edge in [u.top, u.bottom] {
            let reach = Double(edge.w) + Double(u.fade)
            let nx = Double(edge.x), ny = Double(edge.y), offsetDepth = Double(edge.z)
            switch (nx == 0, ny == 0) {
            case (true, true):
                // No edge: everywhere or nowhere.
                if offsetDepth < reach { return nil }
            case (false, true), (true, false):
                let isX = ny == 0
                if let known = bandAxisIsX, known != isX { return nil }
                bandAxisIsX = isX
                let axis = isX ? xAxis : yAxis
                let n = isX ? nx : ny
                switch axis.below(normal: n, offset: offsetDepth, reach: reach) {
                case .none: break
                case .all: return nil
                case let .fromStart(end): low = max(low ?? 0, end)
                case let .toEnd(start): high = min(high ?? axis.count, start)
                }
            case (false, false):
                return nil
            }
        }

        var direct = shown
        var bands: [PixelRect] = []
        if let isX = bandAxisIsX {
            let count = isX ? width : height
            let lo = low ?? 0
            let hi = high ?? count
            guard lo < hi else { return nil }
            func span(_ from: Int, _ to: Int) -> PixelRect {
                isX ? PixelRect(x0: from, y0: 0, x1: to, y1: height) : PixelRect(x0: 0, y0: from, x1: width, y1: to)
            }
            direct = direct.intersection(span(lo, hi))
            if lo > 0 { bands.append(shown.intersection(span(0, lo))) }
            if hi < count { bands.append(shown.intersection(span(hi, count))) }
            bands.removeAll(where: \.isEmpty)
        }
        let banded = bands.reduce(0) { $0 + $1.area }
        guard Double(banded) <= Self.largestBandShare * Double(width * height) else { return nil }

        // How far the taps reach at most, in target pixels: `u_span` runs
        // the effect texture's coordinates per scene point, and that texture
        // spans the bounds.
        let reachX = Double(u.span.x) * Double(u.blur) * Double(bounds.width) * dx
        let reachY = Double(u.span.y) * Double(u.blur) * Double(bounds.height) * dy
        guard reachX.isFinite, reachY.isFinite, reachX >= 0, reachY >= 0 else { return nil }
        // Float noise in `u_span` mustn't round a whole texel up.
        let marginX = Int((reachX - 1e-3).rounded(.up)) + Self.tapMargin
        let marginY = Int((reachY - 1e-3).rounded(.up)) + Self.tapMargin
        strips = bands.map { band in
            let strip = band.insetBy(dx: -marginX, dy: -marginY).intersection(covered)
            return Strip(
                band: band,
                strip: strip,
                span: SIMD2(
                    Float(Double(u.span.x) * Double(bounds.width) * dx / Double(strip.width)),
                    Float(Double(u.span.y) * Double(bounds.height) * dy / Double(strip.height))
                )
            )
        }
        self.direct = direct
    }

    /// The pixels whose centres lie in `from ..< to` (pixel units).
    static func centres(from: Double, to: Double) -> (Int, Int) {
        let lo = Axis.clampedInt((from - 0.5).rounded(.up))
        let hi = Axis.clampedInt((to - 0.5).rounded(.up))
        return (lo, hi)
    }

    /// One axis of the target: the scene coordinate the shader finds at
    /// pixel `i`'s centre is `a + b * (i + 0.5)`.
    struct Axis {
        var a: Double
        var b: Double
        var count: Int

        enum Run: Equatable {
            case none
            case all
            /// Pixels `0 ..< end`.
            case fromStart(Int)
            /// Pixels `start ..< count`.
            case toEnd(Int)
        }

        /// The pixels whose depth `normal * p + offset` is below `reach`:
        /// where the band has any blur at all.
        func below(normal: Double, offset: Double, reach: Double) -> Run {
            // `k * (i + 0.5) + m < 0`.
            let k = normal * b
            let m = normal * a + offset - reach
            if k == 0 { return m < 0 ? .all : .none }
            let edge = -m / k - 0.5
            if k > 0 {
                let end = min(count, max(0, Self.clampedInt(edge.rounded(.up))))
                return end <= 0 ? .none : end >= count ? .all : .fromStart(end)
            }
            let start = min(count, max(0, Self.clampedInt(edge.rounded(.down)) + 1))
            return start >= count ? .none : start <= 0 ? .all : .toEnd(start)
        }

        /// The pixels whose coordinate lies in `low ... high`, clamped to the
        /// target.
        func within(_ low: Double, _ high: Double) -> (Int, Int) {
            guard b != 0 else {
                return a >= low && a <= high ? (0, count) : (0, 0)
            }
            // `i + 0.5` between these two, inclusive.
            let p = (low - a) / b, q = (high - a) / b
            let first = min(p, q) - 0.5, last = max(p, q) - 0.5
            let lo = min(count, max(0, Self.clampedInt(first.rounded(.up))))
            let hi = min(count, max(0, Self.clampedInt(last.rounded(.down)) + 1))
            return (lo, max(lo, hi))
        }

        static func clampedInt(_ value: Double) -> Int {
            guard value.isFinite else { return value > 0 ? Int(Int32.max) : Int(Int32.min) }
            return Int(max(Double(Int32.min), min(Double(Int32.max), value)))
        }
    }

    /// What the contents of an effect covering `bounds` report as
    /// `gl_FragCoord` when drawn into a target whose pixel (0, 0) lies at
    /// `origin` (the effect's own coordinates), `dx` × `dy` pixels a point:
    /// the pixels of the texture they would have drawn into
    /// (`EffectTexture.contentsSpace`), `textureWidth` × `textureHeight`.
    public static func contentsSpace(
        origin: CGPoint, dx: Double, dy: Double,
        bounds: CGRect, textureWidth: Int, textureHeight: Int
    ) -> FragCoordSpace {
        let perX = Double(textureWidth) / Double(bounds.width)
        let perY = Double(textureHeight) / Double(bounds.height)
        return FragCoordSpace(
            offsetX: Float(Double(origin.x - bounds.minX) * perX),
            offsetY: Float(Double(textureHeight) - Double(origin.y - bounds.minY) * perY),
            scaleX: Float(perX / dx),
            scaleY: Float(-perY / dy)
        )
    }

    /// Scene points to clip space for a target showing `rect`.
    public static func projection(showing rect: CGRect) -> [Float] {
        let sx = 2 / Float(rect.width)
        let sy = 2 / Float(rect.height)
        return [
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, -1, 0,
            -1 - Float(rect.minX) * sx, -1 - Float(rect.minY) * sy, 0, 1,
        ]
    }
}
