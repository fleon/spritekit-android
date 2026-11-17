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

    public private(set) var elements: [Element] = []

    public init() {}

    init(elements: [Element]) {
        self.elements = elements
    }

    func append(_ element: Element) { elements.append(element) }
    func append(contentsOf others: [Element]) { elements.append(contentsOf: others) }

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
        storage.append(.arc(center: centre, radius: radius,
                            start: startAngle, end: endAngle, clockwise: clockwise))
    }

    public func append(_ other: UIBezierPath) {
        storage.append(contentsOf: other.storage.elements)
    }

    public func close() { storage.append(.close) }

    public var cgPath: CGPath { storage }
    public var bounds: CGRect { storage.boundingBox }
    public var isEmpty: Bool { storage.elements.isEmpty }
}

/// SpriteKit's numeric range, used by the game's `range(_:_:)` helpers.
public final class SKRange: @unchecked Sendable {
    public var lowerLimit: CGFloat
    public var upperLimit: CGFloat

    public init(lowerLimit: CGFloat, upperLimit: CGFloat) {
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
    }

    public convenience init(constantValue: CGFloat) {
        self.init(lowerLimit: constantValue, upperLimit: constantValue)
    }

    public convenience init(value: CGFloat, variance: CGFloat) {
        self.init(lowerLimit: value - variance, upperLimit: value + variance)
    }
}

#endif
