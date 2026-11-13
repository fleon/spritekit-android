import Foundation
import SpriteKitShim

#if canImport(CoreGraphics) && canImport(Darwin)
import CoreGraphics
#endif

/// A path's segments, in terms both platforms can state.
///
/// On Android `CGPath` is the shim's recorder and hands its elements over
/// directly. On the Mac it is the real CoreGraphics one, and this reads it
/// with `applyWithBlock` — which is what lets the rasteriser, and its tests,
/// run on the host against paths built exactly as the game builds them.
public enum PathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quadCurve(to: CGPoint, control: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    /// Only the shim records these; CoreGraphics turns an arc into curves as
    /// it is added, so a real `CGPath` never reports one.
    case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool)
    case close
}

public extension CGPath {
    /// The path's segments, whichever `CGPath` this is.
    var pathElements: [PathElement] {
        #if canImport(Darwin)
        var out: [PathElement] = []
        applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: out.append(.move(points[0]))
            case .addLineToPoint: out.append(.line(points[0]))
            case .addQuadCurveToPoint: out.append(.quadCurve(to: points[1], control: points[0]))
            case .addCurveToPoint:
                out.append(.curve(to: points[2], control1: points[0], control2: points[1]))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
        #else
        return elements.map {
            switch $0 {
            case let .move(p): return .move(p)
            case let .line(p): return .line(p)
            case let .quadCurve(p, c): return .quadCurve(to: p, control: c)
            case let .curve(p, c1, c2): return .curve(to: p, control1: c1, control2: c2)
            case let .arc(centre, radius, start, end, clockwise):
                return .arc(center: centre, radius: radius, start: start, end: end, clockwise: clockwise)
            case .close: return .close
            }
        }
        #endif
    }
}
