import CAndroidShell
import Foundation
import GLESRenderer
import ShellCore
import SpriteKitShim

/// Rasterised shapes, kept as R8 coverage textures.
///
/// `SKShapeNode`'s path is a value the game rebuilds freely — the loading
/// spinner writes a new one every frame — so the cache cannot key on the
/// path object's identity, or an animated shape would hold a texture per
/// frame for ever and a *reused* path would never be recognised. It keys on
/// what the shape actually draws: the digest of its segments, the fill rule,
/// the stroke's width, cap and join, and the scale it was rasterised at.
///
/// Hashing a few hundred points is far cheaper than rasterising them, so a
/// still shape costs a hash a frame and an animated one costs what it would
/// have cost CoreGraphics.
final class ShapeMasks {
    /// What one shape resolved to this frame.
    struct Entry {
        var name: GLuint
        /// The mask's rectangle in the shape's own coordinates.
        var bounds: CGRect
    }

    private struct Key: Hashable {
        var digest: Int
        var kind: Int               // 0 fill, 1 stroke
        var rule: Int
        var width: Int              // hundredths of a point
        var cap: Int
        var join: Int
        var scale: Int              // hundredths of a pixel per point
    }

    private struct Cached {
        var name: GLuint
        var bounds: CGRect
        var bytes: Int
        var used: UInt64
    }

    /// Masks are a few hundred kilobytes each at worst and the HUD has a
    /// handful on screen. The cap is what stops an animated path (a new
    /// mask a frame) from growing without bound.
    private let budget = 24 * 1024 * 1024

    private var cache: [Key: Cached] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    /// The clock as the frame began: masks staged since are drawn later in
    /// the frame, so they're never evicted before it ends.
    private var frameStart: UInt64 = 0

    private(set) var rasterised = 0

    /// The mask for a shape's fill, rasterised on a miss. Nil when the path
    /// encloses nothing.
    func fill(_ path: CGPath, rule: PathRasteriser.FillRule, scale: CGFloat) -> Entry? {
        let key = Key(
            digest: digest(of: path), kind: 0, rule: rule == .evenOdd ? 1 : 0,
            width: 0, cap: 0, join: 0, scale: quantised(scale)
        )
        return entry(for: key) { PathRasteriser.fill(path, rule: rule, scale: scale) }
    }

    /// The mask for a shape's stroke.
    func stroke(
        _ path: CGPath,
        width: CGFloat,
        cap: CGLineCap,
        join: CGLineJoin,
        scale: CGFloat
    ) -> Entry? {
        let key = Key(
            digest: digest(of: path), kind: 1, rule: 0,
            width: Int((width * 100).rounded()), cap: cap.rawValue, join: join.rawValue,
            scale: quantised(scale)
        )
        return entry(for: key) {
            PathRasteriser.stroke(path, width: width, cap: cap, join: join, scale: scale)
        }
    }

    func beginFrame() { frameStart = clock + 1 }

    func removeAll() {
        for entry in cache.values {
            var name = entry.name
            glDeleteTextures(1, &name)
        }
        cache.removeAll()
        bytes = 0
    }

    // MARK: Behind it

    private func entry(for key: Key, make: () -> PathRasteriser.Mask?) -> Entry? {
        clock += 1
        if var hit = cache[key] {
            hit.used = clock
            cache[key] = hit
            return Entry(name: hit.name, bounds: hit.bounds)
        }
        guard let mask = make(), !mask.isEmpty else { return nil }
        guard let name = upload(mask) else { return nil }

        rasterised += 1
        cache[key] = Cached(name: name, bounds: mask.bounds, bytes: mask.byteCount, used: clock)
        bytes += mask.byteCount
        evictIfNeeded()
        return Entry(name: name, bounds: mask.bounds)
    }

    private func evictIfNeeded() {
        guard bytes > budget else { return }
        for (key, entry) in cache.sorted(by: { $0.value.used < $1.value.used }) where entry.used < frameStart {
            var name = entry.name
            glDeleteTextures(1, &name)
            cache.removeValue(forKey: key)
            bytes -= entry.bytes
            if bytes <= budget / 2 { break }
        }
    }

    private func upload(_ mask: PathRasteriser.Mask) -> GLuint? {
        var name: GLuint = 0
        glGenTextures(1, &name)
        guard name != 0 else {
            Log.error("glGenTextures gave 0 for a shape mask")
            return nil
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        // A mask's own margin is transparent, so clamping cannot smear its
        // last column across the quad's edge.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        mask.pixels.withUnsafeBufferPointer { bytes in
            glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_R8,
                GLsizei(mask.width), GLsizei(mask.height), 0,
                GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress
            )
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        return name
    }

    /// Scale is quantised so that a shape easing through a scale animation
    /// does not rasterise at every intermediate size. A twentieth of a pixel
    /// per point is below what the eye reads as a resampling step.
    private func quantised(_ scale: CGFloat) -> Int { Int((scale * 20).rounded()) }

    /// A hash of what the path draws. Hashing is what makes the cache work
    /// across rebuilt paths — the game's helpers make a new `UIBezierPath`
    /// each time a node lays out, with the same shape in it.
    private func digest(of path: CGPath) -> Int {
        var hasher = Hasher()
        for element in path.pathElements {
            switch element {
            case let .move(p): hasher.combine(0); combine(p, into: &hasher)
            case let .line(p): hasher.combine(1); combine(p, into: &hasher)
            case let .quadCurve(p, c):
                hasher.combine(2); combine(p, into: &hasher); combine(c, into: &hasher)
            case let .curve(p, c1, c2):
                hasher.combine(3)
                combine(p, into: &hasher); combine(c1, into: &hasher); combine(c2, into: &hasher)
            case let .arc(centre, radius, start, end, clockwise):
                hasher.combine(4)
                combine(centre, into: &hasher)
                hasher.combine(quantise(radius))
                hasher.combine(quantise(start))
                hasher.combine(quantise(end))
                hasher.combine(clockwise)
            case .close: hasher.combine(5)
            }
        }
        return hasher.finalize()
    }

    private func combine(_ point: CGPoint, into hasher: inout Hasher) {
        hasher.combine(quantise(point.x))
        hasher.combine(quantise(point.y))
    }

    /// Coordinates are compared at a thousandth of a point: far finer than
    /// anything that could show, and it keeps the key an integer, so the
    /// float noise of a rebuilt path does not miss its own cache entry.
    private func quantise(_ value: CGFloat) -> Int {
        value.isFinite ? Int((value * 1000).rounded()) : 0
    }
}
