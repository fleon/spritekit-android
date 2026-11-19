#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

public enum CGLineCap: Int, Sendable { case butt, round, square }
public enum CGLineJoin: Int, Sendable { case miter, round, bevel }

/// A recorded 2D path.
///
/// The shim records; the renderer rasterises. Every vector shape a game
/// draws (buttons, panels, meters, focus rings) comes through here or
/// through CGContext, so this and a scanline filler are what replace
/// CoreGraphics on Android.
public final class CGPath: @unchecked Sendable {
    public enum Element {
        case move(CGPoint)
        case line(CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool)
        case close
    }

    public private(set) var elements: [Element] = [] {
        didSet { version &+= 1 }
    }

    /// Counts changes to the recording, so a renderer holding this path can
    /// tell it is unchanged without reading it again.
    public private(set) var version = 0

    public init() {}

    init(elements: [Element]) {
        self.elements = elements
    }

    func append(_ element: Element) { elements.append(element) }

    /// Whether the path has a pen to carry on from: anything but closes, as
    /// `PathGeometry.currentPoint` reads it. Stops at the first element that
    /// isn't a close, so it's cheap however long the path.
    var hasPen: Bool {
        elements.contains { if case .close = $0 { return false } else { return true } }
    }
    func append(contentsOf others: [Element]) { elements.append(contentsOf: others) }

    /// Replaces the recording with `pathElements` (portable segments, as
    /// `PathGeometry` edits them).
    func replace(with pathElements: [PathElement]) {
        elements = pathElements.map {
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
    }

    /// The path's control-point bounds. Curves are not flattened, so this is
    /// conservative — as CGPath's own `boundingBox` is.
    public var boundingBox: CGRect {
        var points: [CGPoint] = []
        for element in elements {
            switch element {
            case let .move(p), let .line(p): points.append(p)
            case let .quadCurve(p, c): points.append(contentsOf: [p, c])
            case let .curve(p, c1, c2): points.append(contentsOf: [p, c1, c2])
            case let .arc(centre, radius, _, _, _):
                points.append(contentsOf: [
                    CGPoint(x: centre.x - radius, y: centre.y - radius),
                    CGPoint(x: centre.x + radius, y: centre.y + radius),
                ])
            case .close: break
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// UIKit's path builder, as the game's `path(_:)` and `shape(_:)` helpers use it.
public final class UIBezierPath: @unchecked Sendable {
    private let storage = CGPath()

    public var lineWidth: CGFloat = 1
    public var lineCapStyle: CGLineCap = .butt
    public var lineJoinStyle: CGLineJoin = .miter

    public init() {}

    public convenience init(rect: CGRect) {
        self.init()
        move(to: CGPoint(x: rect.minX, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        close()
    }

    public convenience init(ovalIn rect: CGRect) {
        self.init()
        // A circle or ellipse as four cubic arcs, the usual kappa.
        let k: CGFloat = 0.5522847498
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        let (rx, ry) = (w / 2, h / 2)
        let centre = CGPoint(x: x + rx, y: y + ry)
        move(to: CGPoint(x: centre.x, y: y + h))
        addCurve(to: CGPoint(x: x + w, y: centre.y),
                 controlPoint1: CGPoint(x: centre.x + rx * k, y: y + h),
                 controlPoint2: CGPoint(x: x + w, y: centre.y + ry * k))
        addCurve(to: CGPoint(x: centre.x, y: y),
                 controlPoint1: CGPoint(x: x + w, y: centre.y - ry * k),
                 controlPoint2: CGPoint(x: centre.x + rx * k, y: y))
        addCurve(to: CGPoint(x: x, y: centre.y),
                 controlPoint1: CGPoint(x: centre.x - rx * k, y: y),
                 controlPoint2: CGPoint(x: x, y: centre.y - ry * k))
        addCurve(to: CGPoint(x: centre.x, y: y + h),
                 controlPoint1: CGPoint(x: x, y: centre.y + ry * k),
                 controlPoint2: CGPoint(x: centre.x - rx * k, y: y + h))
        close()
    }

    public convenience init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        self.init()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard r > 0 else {
            append(UIBezierPath(rect: rect))
            return
        }
        move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
               startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
               startAngle: 0, endAngle: .pi / 2, clockwise: true)
        addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
               startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
               startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        close()
    }

    public convenience init(cgPath: CGPath) {
        self.init()
        storage.append(contentsOf: cgPath.elements)
    }

    /// An arc on its own, as UIKit's initializer: its subpath starts at the
    /// arc's first point.
    public convenience init(
        arcCenter center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool
    ) {
        self.init()
        addArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
    }

    /// Where the pen is: the last point drawn to, the subpath's start after
    /// a close, `.zero` on an empty path.
    public var currentPoint: CGPoint {
        PathGeometry.currentPoint(after: storage.pathElements) ?? .zero
    }

    /// Moves every point of the path through `transform` (arcs become the
    /// curves CoreGraphics would have recorded for them).
    public func apply(_ transform: CGAffineTransform) {
        storage.replace(with: PathGeometry.transformed(storage.pathElements, by: transform))
    }

    /// The same path drawn the other way: each subpath reversed, in order,
    /// as UIKit does (`PathGeometry.reversed`, measured against AppKit's).
    public func reversing() -> UIBezierPath {
        let reversed = UIBezierPath()
        reversed.storage.replace(with: PathGeometry.reversed(storage.pathElements))
        reversed.lineWidth = lineWidth
        reversed.lineCapStyle = lineCapStyle
        reversed.lineJoinStyle = lineJoinStyle
        return reversed
    }

    public func move(to point: CGPoint) { storage.append(.move(point)) }
    public func addLine(to point: CGPoint) { storage.append(.line(point)) }

    public func addQuadCurve(to point: CGPoint, controlPoint: CGPoint) {
        storage.append(.quadCurve(to: point, control: controlPoint))
    }

    public func addCurve(to point: CGPoint, controlPoint1: CGPoint, controlPoint2: CGPoint) {
        storage.append(.curve(to: point, control1: controlPoint1, control2: controlPoint2))
    }

    public func addArc(
        withCenter centre: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool
    ) {
        storage.append(portable: PathGeometry.arc(
            center: centre, radius: radius, start: startAngle, end: endAngle, clockwise: clockwise,
            hasPen: storage.hasPen
        ))
    }

    public func append(_ other: UIBezierPath) {
        storage.append(contentsOf: other.storage.elements)
    }

    public func close() { storage.append(.close) }

    public var cgPath: CGPath { storage }
    public var bounds: CGRect { storage.boundingBox }
    public var isEmpty: Bool { storage.elements.isEmpty }
}

#endif
