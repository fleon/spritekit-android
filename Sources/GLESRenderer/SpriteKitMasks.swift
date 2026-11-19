import Foundation
import SpriteKitShim

/// The masks a shape node draws through when it can't be triangles
/// (`ShapeMasks`: a textured fill, a self-crossing or nested fill, a crop's
/// mask), with the same edges as the triangles (`ShapeTessellator.Edges.spriteKit`):
/// a fill sampled at pixel centres and not antialiased, a stroke softened
/// as SpriteKit softens one. A `CGContext`'s drawing keeps CoreGraphics'
/// exact coverage (`PathRasteriser`).
public enum SpriteKitMasks {

    /// A fill, flattened as finely as the triangles' fills (four times the
    /// stroke's), each pixel in when its centre is.
    public static func fill(_ path: CGPath, rule: PathRasteriser.FillRule = .nonZero, scale: CGFloat) -> PathRasteriser.Mask? {
        guard scale > 0 else { return nil }
        let polygons = PathRasteriser.flatten(path, scale: scale * 4).map(\.points).filter { $0.count > 2 }
        return PathRasteriser.rasteriseCentreSampled(polygons, rule: rule, scale: scale)
    }

    /// A stroke: its triangles as the mesh path makes them, sampled at
    /// pixel centres, so a stroke drawn through its mask and one drawn as
    /// triangles cover the same pixels. One too big for triangles keeps
    /// CoreGraphics' stroke.
    public static func stroke(
        _ path: CGPath,
        width: CGFloat,
        cap: CGLineCap,
        join: CGLineJoin,
        scale: CGFloat,
        edgePixels: CGFloat,
        glow: CGFloat = 0,
        antialiased: Bool = true,
        miterClip: CGFloat? = nil
    ) -> PathRasteriser.Mask? {
        guard scale > 0, width > 0 else { return nil }
        guard let mesh = ShapeTessellator.stroke(
            PathRasteriser.flatten(path, scale: scale), width: width, cap: cap, join: join,
            miterLimit: .greatestFiniteMagnitude, scale: scale,
            edges: .spriteKit, edgePixels: edgePixels, glow: glow, antialiased: antialiased,
            miterClip: miterClip ?? ShapeMeshes.miterClip(limit: 0.5, width: width)
        ) else {
            return PathRasteriser.stroke(path, width: width, cap: cap, join: join, scale: scale)
        }
        return rasterise(mesh, scale: scale)
    }

    /// How far off a pixel's centre it is sampled, in pixels: never exactly
    /// on an edge two triangles share, which would count twice, where the
    /// GPU's rule counts it once.
    static let sampleNudge = SIMD2<Float>(0.000137, 0.000291)

    /// A mesh's coverage at each pixel's centre, interpolated across its
    /// triangles and composited where they overlap, as the GPU draws it.
    static func rasterise(_ mesh: ShapeTessellator.Mesh, scale: CGFloat) -> PathRasteriser.Mask? {
        guard !mesh.isEmpty else { return nil }
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for p in mesh.positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        // A pixel of margin all round, as the rasteriser's masks have.
        let margin = 1 / scale
        let bounds = CGRect(
            x: CGFloat(minX) - margin, y: CGFloat(minY) - margin,
            width: CGFloat(maxX - minX) + margin * 2, height: CGFloat(maxY - minY) + margin * 2
        )
        let width = max(1, Int((bounds.width * scale - 1e-6).rounded(.up)))
        let height = max(1, Int((bounds.height * scale - 1e-6).rounded(.up)))
        guard width <= 8192, height <= 8192 else { return nil }

        // Into pixels, row 0 at the top: y grows down the mask.
        let s = Float(scale), left = Float(bounds.minX), top = Float(bounds.maxY)
        let pixels = mesh.positions.map { SIMD2(($0.x - left) * s, (top - $0.y) * s) }
        // Bytes from the start, touched only inside a triangle's box: a thin
        // outline round a full-screen panel covers a few percent of its
        // mask, and a float a pixel converted at the end cost more than the
        // triangles did.
        var bytes = [UInt8](repeating: 0, count: width * height)
        var touched = false
        bytes.withUnsafeMutableBufferPointer { out in
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let a = pixels[ia], b = pixels[ib], c = pixels[ic]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-12 else { continue }
            let x0 = max(0, Int(min(a.x, b.x, c.x).rounded(.down))), x1 = min(width - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let y0 = max(0, Int(min(a.y, b.y, c.y).rounded(.down))), y1 = min(height - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let ca = mesh.coverage[ia], cb = mesh.coverage[ib], cc = mesh.coverage[ic]
            for y in y0 ... y1 {
                let py = Float(y) + 0.5 + sampleNudge.y
                for x in x0 ... x1 {
                    let px = Float(x) + 0.5 + sampleNudge.x
                    let wa = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area
                    let wb = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area
                    let wc = 1 - wa - wb
                    guard wa >= 0, wb >= 0, wc >= 0 else { continue }
                    let value = wa * ca + wb * cb + wc * cc
                    guard value > 0 else { continue }
                    let i = y * width + x
                    let under = Float(out[i]) / 255
                    out[i] = UInt8(max(0, min(255, ((value + under * (1 - value)) * 255).rounded())))
                    touched = true
                }
            }
        }
        }
        guard touched, bytes.contains(where: { $0 > 0 }) else { return nil }
        return PathRasteriser.Mask(width: width, height: height, pixels: bytes, bounds: bounds, scale: scale)
    }
}
