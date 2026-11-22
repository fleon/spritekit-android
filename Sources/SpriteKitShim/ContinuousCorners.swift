#if SPRITEKIT_SHIM
import Foundation

#if canImport(CoreGraphics) && canImport(Darwin)
import CoreGraphics
#endif

/// UIKit's continuous rounded rect (`UIBezierPath(roundedRect:cornerRadius:)`
/// and `UIBezierPath(roundedRect:byRoundingCorners:cornerRadii:)`, as iOS 7
/// and later draw them), for where there is no UIKit to draw it: its corners
/// ease into the edges rather than meeting them as a circle's arc does. The
/// shim's `UIBezierPath` draws through this on Android, and the toolkit's
/// `path(.continuousRoundedRect)` on the Mac host. The curves and the rules
/// are UIKit's, measured from its paths on a Mac (Catalyst).
///
/// Each edge leaves a corner room to run: half the edge when both its ends
/// are rounded, all of it when one is. With `reach` × radius against that
/// room, each rounded corner takes one of three shapes:
///
/// - while it fits along both its edges, one shape scaled by the radius,
///   reaching `reach` × radius along each;
/// - while it fits along the roomier one, another fixed shape, scaled by
///   half the other edge and running to that edge's middle;
/// - otherwise a circle's quarter, of 0.93125 × half the shorter side.
///
/// When every rounded corner is a circle and the rounded corners include
/// two opposite ones, UIKit draws a capsule instead: all four corners
/// circles of half the shorter side, rounded or not.
public nonisolated enum ContinuousCorners {
    /// How far along each edge a corner reaches, per point of radius.
    public static let reach: CGFloat = 1.5286649847

    /// Which corners to round, as `UIRectCorner` names them (y down).
    public struct Corners: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let topLeft = Corners(rawValue: 1 << 0)
        public static let topRight = Corners(rawValue: 1 << 1)
        public static let bottomLeft = Corners(rawValue: 1 << 2)
        public static let bottomRight = Corners(rawValue: 1 << 3)
        public static let all: Corners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    /// Adds the rounded rect as a closed subpath, clockwise in UIKit's y-down
    /// space from the top edge, as UIKit's path runs. A radius of zero, or
    /// no corners, is a plain rect; a negative one turns each corner's
    /// curve inside out, as UIKit's does.
    public static func addRoundedRect(
        to path: CGMutablePath,
        in rect: CGRect,
        corners: Corners = .all,
        cornerRadius: CGFloat
    ) {
        let frame = rect.standardized
        let radius = cornerRadius
        guard radius != 0, !corners.isDisjoint(with: .all), frame.width > 0, frame.height > 0 else {
            path.addRect(frame)
            return
        }
        let half = min(frame.width, frame.height) / 2
        let span = radius * reach
        // Clockwise (y down) from the top right, as the path visits them.
        let order: [Corners] = [.topRight, .bottomRight, .bottomLeft, .topLeft]
        // Each corner's incoming edge, then its outgoing one: top, right,
        // bottom, left.
        let edgeLength = [frame.width, frame.height, frame.width, frame.height]
        let edgeRoom = (0..<4).map { edge -> CGFloat in
            // Edge `i` runs from corner `i - 1` into corner `i`.
            let bothRounded = corners.contains(order[(edge + 3) % 4]) && corners.contains(order[edge])
            return bothRounded ? edgeLength[edge] / 2 : edgeLength[edge]
        }

        enum Shape { case square, standard, middle, circle }
        let shapes = (0..<4).map { index -> Shape in
            guard corners.contains(order[index]) else { return .square }
            let rooms = (edgeRoom[index], edgeRoom[(index + 1) % 4])
            if span <= min(rooms.0, rooms.1) { return .standard }
            return span <= max(rooms.0, rooms.1) ? .middle : .circle
        }
        let opposite = corners.isSuperset(of: [.topLeft, .bottomRight]) || corners.isSuperset(of: [.topRight, .bottomLeft])
        if opposite, !shapes.contains(.standard), !shapes.contains(.middle) {
            addCorners(to: path, frame) { _ in circle(half) }
            return
        }
        addCorners(to: path, frame) { index in
            switch shapes[index] {
            case .square:
                return Run(start: Offset(along: 0, out: 0), curves: [])
            case .standard:
                return standard.scaled(radius)
            case .middle:
                // The side with less room ends at its middle; the corner
                // starts `span` along the other, if that's the way it's
                // entered.
                let entersRoomier = edgeRoom[index] > edgeRoom[(index + 1) % 4]
                let scale = (entersRoomier ? edgeLength[(index + 1) % 4] : edgeLength[index]) / 2
                return (entersRoomier ? Middle.fromLong(startingAt: span / scale) : Middle.fromShort).scaled(scale)
            case .circle:
                return circle(half * circleShare)
            }
        }
    }

    // MARK: Geometry

    /// A circle's control points in a quarter turn, per point of radius.
    private static let kappa: CGFloat = 0.5522847498

    /// A lone circular corner's radius, per point of half the shorter side.
    private static let circleShare: CGFloat = 0.93124985

    /// A point near a corner: `along` back up the edge the path comes in
    /// on, `out` down the edge it leaves by.
    private struct Offset {
        var along: CGFloat
        var out: CGFloat
        func scaled(_ s: CGFloat) -> Offset { Offset(along: along * s, out: out * s) }
    }

    /// A corner's run: where it starts (on the incoming edge) and the curves
    /// it takes, each `(control1, control2, end)`.
    private struct Run {
        var start: Offset
        var curves: [(Offset, Offset, Offset)]
        /// A line on to the outgoing side's middle, when a corner leaves the
        /// side with no straight part.
        var lineTo: Offset?

        func scaled(_ s: CGFloat) -> Run {
            Run(start: start.scaled(s), curves: curves.map { ($0.0.scaled(s), $0.1.scaled(s), $0.2.scaled(s)) }, lineTo: lineTo?.scaled(s))
        }
    }

    /// The corner while it fits, per point of radius.
    private static let standard = Run(
        start: Offset(along: reach, out: 0),
        curves: [
            (Offset(along: 1.0884929576, out: 0), Offset(along: 0.8684069441, out: 0), Offset(along: 0.6314937928, out: 0.0749113878)),
            (Offset(along: 0.3728238266, out: 0.1690595560), Offset(along: 0.1690595560, out: 0.3728238266), Offset(along: 0.0749113878, out: 0.6314937928)),
            (Offset(along: 0, out: 0.8684069441), Offset(along: 0, out: 1.0884929576), Offset(along: 0, out: reach)),
        ]
    )

    /// A circle's quarter of `radius`.
    private static func circle(_ radius: CGFloat) -> Run {
        let control = radius * (1 - kappa)
        return Run(
            start: Offset(along: radius, out: 0),
            curves: [(Offset(along: control, out: 0), Offset(along: 0, out: control), Offset(along: 0, out: radius))]
        )
    }

    /// The corner past that, per point of half the side with less room.
    private enum Middle {
        /// How far along the roomier side it reaches as it leaves a corner.
        static let longReach: CGFloat = 1.5099148347
        static func fromLong(startingAt start: CGFloat) -> Run {
            Run(
                start: Offset(along: start, out: 0),
                curves: [
                    (Offset(along: 1.0697428076, out: 0), Offset(along: 0.8496567941, out: 0), Offset(along: 0.6127436428, out: 0.0749113878)),
                    (Offset(along: 0.2448578034, out: 0.2088108830), Offset(along: 0, out: 0.5585040669), Offset(along: 0, out: 0.95)),
                ],
                lineTo: Offset(along: 0, out: 1)
            )
        }
        static let fromShort = Run(
            start: Offset(along: 0.95, out: 0),
            curves: [
                (Offset(along: 0.5585040669, out: 0), Offset(along: 0.2088108830, out: 0.2448578034), Offset(along: 0.0749113878, out: 0.6127436428)),
                (Offset(along: 0, out: 0.8496567941), Offset(along: 0, out: 1.0697428076), Offset(along: 0, out: longReach)),
            ]
        )
    }

    /// The four corners clockwise (y down) from the top right, each from
    /// its incoming edge; `run(i)` gives corner `i`'s.
    private static func addCorners(to path: CGMutablePath, _ frame: CGRect, run: (Int) -> Run) {
        // Each corner's point, the way back up its incoming edge and the
        // way down its outgoing one, in y-down terms.
        typealias Way = (dx: CGFloat, dy: CGFloat)
        let corners: [(CGPoint, Way, Way)] = [
            (CGPoint(x: frame.maxX, y: frame.minY), (-1, 0), (0, 1)),
            (CGPoint(x: frame.maxX, y: frame.maxY), (0, -1), (-1, 0)),
            (CGPoint(x: frame.minX, y: frame.maxY), (1, 0), (0, -1)),
            (CGPoint(x: frame.minX, y: frame.minY), (0, 1), (1, 0)),
        ]
        for (index, (corner, back, down)) in corners.enumerated() {
            func point(_ offset: Offset) -> CGPoint {
                CGPoint(x: corner.x + back.dx * offset.along + down.dx * offset.out,
                        y: corner.y + back.dy * offset.along + down.dy * offset.out)
            }
            let run = run(index)
            if index == 0 {
                path.move(to: point(run.start))
            } else {
                path.addLine(to: point(run.start))
            }
            for (control1, control2, end) in run.curves {
                path.addCurve(to: point(end), control1: point(control1), control2: point(control2))
            }
            if let lineTo = run.lineTo { path.addLine(to: point(lineTo)) }
        }
        path.closeSubpath()
    }
}
#endif
