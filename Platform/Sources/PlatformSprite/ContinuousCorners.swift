import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import CoreGraphics
#endif

/// UIKit's continuous rounded rect (`UIBezierPath(roundedRect:cornerRadius:)`,
/// as iOS 7 and later draw it), for where there is no UIKit to draw it: its
/// corners ease into the edges rather than meeting them as a circle's arc
/// does. The curves are UIKit's, measured from its paths on a Mac (Catalyst):
///
/// - while `1.5287 × radius` fits in half the shorter side, each corner is
///   one shape, scaled by the radius, reaching 1.5287 × radius along each
///   edge;
/// - past that, up to a radius of half the shorter side, each corner of a
///   rect that isn't square is another fixed shape, scaled by half the
///   shorter side, the shorter sides left with no straight part;
/// - otherwise (a larger radius, or a square) the corners are circles of
///   half the shorter side, as a capsule's.
public nonisolated enum ContinuousCorners {
    /// How far along each edge a corner reaches, per point of radius.
    public static let reach: CGFloat = 1.5286649847

    /// Adds the rounded rect as a closed subpath, clockwise in UIKit's y-down
    /// space from the top edge, as UIKit's path runs.
    public static func addRoundedRect(to path: CGMutablePath, in rect: CGRect, cornerRadius: CGFloat) {
        let frame = rect.standardized
        let half = min(frame.width, frame.height) / 2
        let radius = max(0, cornerRadius)
        guard radius > 0, half > 0 else {
            path.addRect(frame)
            return
        }
        if radius * reach <= half {
            addCorners(to: path, frame, from: radius * reach) { _ in standard.map { $0.scaled(radius) } }
        } else if radius <= half, frame.width != frame.height {
            let wide = frame.width > frame.height
            // UIKit starts on the top edge 1.5287 × radius in when it is a
            // long side, else at its middle.
            addCorners(to: path, frame, from: wide ? radius * reach : half) { corner in
                // Whether this corner is entered along a long side; there,
                // as UIKit's, the curve starts 1.5287 × radius from it.
                let entersLong = (corner % 2 == 0) == wide
                return (entersLong ? Middle.fromLong(startingAt: radius * reach / half) : Middle.fromShort).map { $0.scaled(half) }
            }
        } else {
            path.addRoundedRect(in: frame, cornerWidth: half, cornerHeight: half)
        }
    }

    // MARK: Geometry

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
    private static let standard: [Run] = [Run(
        start: Offset(along: reach, out: 0),
        curves: [
            (Offset(along: 1.0884929576, out: 0), Offset(along: 0.8684069441, out: 0), Offset(along: 0.6314937928, out: 0.0749113878)),
            (Offset(along: 0.3728238266, out: 0.1690595560), Offset(along: 0.1690595560, out: 0.3728238266), Offset(along: 0.0749113878, out: 0.6314937928)),
            (Offset(along: 0, out: 0.8684069441), Offset(along: 0, out: 1.0884929576), Offset(along: 0, out: reach)),
        ]
    )]

    /// The corner past that, per point of half the shorter side.
    private enum Middle {
        /// How far along a long side it reaches as it leaves a corner.
        static let longReach: CGFloat = 1.5099148347
        static func fromLong(startingAt start: CGFloat) -> [Run] { [Run(
            start: Offset(along: start, out: 0),
            curves: [
                (Offset(along: 1.0697428076, out: 0), Offset(along: 0.8496567941, out: 0), Offset(along: 0.6127436428, out: 0.0749113878)),
                (Offset(along: 0.2448578034, out: 0.2088108830), Offset(along: 0, out: 0.5585040669), Offset(along: 0, out: 0.95)),
            ],
            lineTo: Offset(along: 0, out: 1)
        )] }
        static let fromShort: [Run] = [Run(
            start: Offset(along: 0.95, out: 0),
            curves: [
                (Offset(along: 0.5585040669, out: 0), Offset(along: 0.2088108830, out: 0.2448578034), Offset(along: 0.0749113878, out: 0.6127436428)),
                (Offset(along: 0, out: 0.8496567941), Offset(along: 0, out: 1.0697428076), Offset(along: 0, out: longReach)),
            ]
        )]
    }

    /// The four corners clockwise (y down) from the top right, each from
    /// its incoming edge; `runs(i)` gives corner `i`'s.
    private static func addCorners(to path: CGMutablePath, _ frame: CGRect, from start: CGFloat, runs: (Int) -> [Run]) {
        path.move(to: CGPoint(x: frame.minX + start, y: frame.minY))
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
            for run in runs(index) {
                path.addLine(to: point(run.start))
                for (control1, control2, end) in run.curves {
                    path.addCurve(to: point(end), control1: point(control1), control2: point(control2))
                }
                if let lineTo = run.lineTo { path.addLine(to: point(lineTo)) }
            }
        }
        path.closeSubpath()
    }
}
