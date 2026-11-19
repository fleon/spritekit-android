import Foundation
import SpriteKitShim

/// Which `SKCropNode`s draw offscreen and multiply their contents by their
/// mask, rather than clipping through the stencil.
///
/// Measured in an `SKView` on the iPhone 17 Pro simulator (3x): a sprite as
/// a crop's mask clips where its alpha is at least about 0.05, all or
/// nothing, which the stencil does exactly (`maskFragmentShader`). A shape
/// node as the mask does not: its fill's alpha passes through (a fill at
/// 0.3 leaves 0.3 of the contents), and its edge is soft, about 2.5 pixels
/// on average, though a shape drawn on its own has a hard one. So a crop
/// whose mask holds a shape is drawn into a target of its own and
/// multiplied by the mask's coverage (`cropCompositeFragmentShader`).
public enum CropCompositing {
    public enum Mode: String, Sendable {
        /// Every crop through the stencil, shape masks cut at half coverage.
        case stencil
        /// Offscreen only where a shape mask would visibly differ: a fill
        /// that isn't opaque, or a stroke (its soft edge multiplies in).
        case hybrid
        /// Offscreen for every crop whose mask holds a shape: Apple's soft
        /// edge everywhere.
        case composited
    }

    nonisolated(unsafe) public static var mode: Mode = .composited

    /// Whether a crop with this mask is composited under `mode`.
    public static func composites(_ mask: [SpriteBatcher.Pass], mode: Mode = mode) -> Bool {
        guard mode != .stencil else { return false }
        var shapes: [DrawList.Shape] = []
        guard collectShapes(mask, into: &shapes), !shapes.isEmpty else { return false }
        if mode == .composited { return true }
        return shapes.contains { shape in
            let fills = shape.fillColor.alpha > 0
            let strokes = shape.lineWidth > 0 && shape.strokeColor.alpha > 0
            let translucent = fills && shape.fillColor.alpha * shape.alpha < 0.999
                || !fills && shape.alpha < 0.999
            return strokes || translucent
        }
    }

    /// The shapes in a mask; false when the mask holds what a composite
    /// doesn't take (a nested crop or effect node, kept on the stencil).
    private static func collectShapes(_ passes: [SpriteBatcher.Pass], into shapes: inout [DrawList.Shape]) -> Bool {
        for pass in passes {
            switch pass {
            case .batches, .label:
                continue
            case let .shape(shape):
                shapes.append(shape)
            case let .coverage(staged):
                if case let .shape(shape) = staged.origin { shapes.append(shape) }
            case .effect, .crop:
                return false
            }
        }
        return true
    }

    /// Where a mask reaches, in the space its passes are drawn in, from the
    /// vertices it was staged with: nil when it draws nothing, or holds what
    /// can't be measured this way (a shape not yet made into coverage).
    public static func bounds(of mask: [SpriteBatcher.Pass]) -> CGRect? {
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        func take(_ vertices: [Float]) {
            var i = 0
            while i + 1 < vertices.count {
                minX = min(minX, vertices[i]); maxX = max(maxX, vertices[i])
                minY = min(minY, vertices[i + 1]); maxY = max(maxY, vertices[i + 1])
                i += SpriteBatcher.floatsPerVertex
            }
        }
        for pass in mask {
            switch pass {
            case let .batches(batches):
                for batch in batches { take(batch.vertices) }
            case let .coverage(staged):
                for part in staged.parts { take(part.run.vertices) }
            case .shape, .label, .effect, .crop:
                return nil
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}
