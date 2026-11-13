#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// CoreGraphics' mutable path. On Apple it is a subclass of `CGPath`; here
/// `CGPath` records rather than holding a CoreGraphics object, so there is
/// nothing for the two to differ in and the names can be the same type.
///
/// Only the three calls the rigs make are here — a clipping mask is a closed
/// polygon and nothing more. The other 60-odd path calls in the game
/// (`SVGPath`, `SurfaceTexture`, `EdgeNode`, the chunky surfaces) come with
/// the rasteriser, which is what has to draw them.
public typealias CGMutablePath = CGPath

public extension CGPath {
    func move(to point: CGPoint) { append(.move(point)) }

    func addLine(to point: CGPoint) { append(.line(point)) }

    /// The first point is moved to, the rest lined to, as CoreGraphics does.
    func addLines(between points: [CGPoint]) {
        guard let first = points.first else { return }
        append(.move(first))
        for point in points.dropFirst() { append(.line(point)) }
    }

    func closeSubpath() { append(.close) }
}
#endif
