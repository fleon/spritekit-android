import Foundation
import SpriteKitShim

/// A timing curve: progress from 0 to 1 eased. `bezier` solves CSS-style
/// cubic-bezier curves, so a web prototype's timings carry over exactly.
public nonisolated struct TimingCurve: Sendable {
    public let value: @Sendable (CGFloat) -> CGFloat

    public init(_ value: @escaping @Sendable (CGFloat) -> CGFloat) {
        self.value = value
    }

    public func callAsFunction(_ progress: CGFloat) -> CGFloat {
        value(progress.clamp(0, 1))
    }

    public static let linear = TimingCurve { $0 }
    public static let easeIn = TimingCurve { $0 * $0 * $0 }
    public static let easeOut = TimingCurve { 1 - pow(1 - $0, 3) }
    public static let easeInOut = bezier(0.42, 0, 0.58, 1)
    public static let cssEaseOut = bezier(0, 0, 0.58, 1)
    /// A long, soft landing.
    public static let quintOut = TimingCurve { 1 - pow(1 - $0, 5) }

    /// Overshoots the destination before settling back.
    public static let backOut = TimingCurve { time in
        let overshoot: CGFloat = 1.70158
        let shifted = time - 1
        return shifted * shifted * ((overshoot + 1) * shifted + overshoot) + 1
    }

    /// Pulls back past the start before heading off: `backOut` run backwards.
    public static let backIn = TimingCurve { time in
        let overshoot: CGFloat = 1.70158
        return time * time * ((overshoot + 1) * time - overshoot)
    }

    /// Pulls back, then overshoots: `backIn` into `backOut`.
    public static let backInOut = TimingCurve { progress in
        let overshoot: CGFloat = 1.70158 * 1.525
        let time = progress * 2
        if time < 1 { return time * time * ((overshoot + 1) * time - overshoot) / 2 }
        let shifted = time - 2
        return (shifted * shifted * ((overshoot + 1) * shifted + overshoot)) / 2 + 1
    }

    /// CSS's `cubic-bezier(x1, y1, x2, y2)`.
    public static func bezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> TimingCurve {
        @Sendable func sample(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        @Sendable func slope(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
        }
        return TimingCurve { x in
            var t = x
            for _ in 0..<8 {
                let error = sample(t, x1, x2) - x
                let derivative = slope(t, x1, x2)
                guard abs(error) > 1e-5, abs(derivative) > 1e-6 else { break }
                t = (t - error / derivative).clamp(0, 1)
            }
            return sample(t, y1, y2)
        }
    }
}

extension SKAction {
    /// How long past its duration `animateSteadily` may run to catch up,
    /// and the most one frame moves it on. A game may set them at launch.
    public nonisolated(unsafe) static var steadyCatchUp: TimeInterval = 0.5
    public nonisolated(unsafe) static var steadyFrameStep: TimeInterval = 1.0 / 30

    /// Runs `update` with eased progress from 0 to 1.
    public static func animate(
        duration: TimeInterval,
        curve: TimingCurve = .linear,
        _ update: @escaping (SKNode, CGFloat) -> Void
    ) -> SKAction {
        guard duration > 0 else { return .run { } }
        return .customAction(withDuration: duration) { node, elapsed in
            update(node, curve(elapsed / CGFloat(duration)))
        }
    }

    public static func scale(
        from start: CGFloat,
        to end: CGFloat,
        duration: TimeInterval,
        curve: TimingCurve
    ) -> SKAction {
        .animate(duration: duration, curve: curve) { node, progress in
            node.setScale(progress.lerp(start, end))
        }
    }

    public static func move(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        curve: TimingCurve
    ) -> SKAction {
        .animate(duration: duration, curve: curve) { node, progress in
            node.position = progress.lerp(start, end)
        }
    }

    /// Like `animate`, but a long frame (a panel being built and its
    /// textures uploaded) doesn't skip the start: each frame moves it on by
    /// at most `steadyFrameStep`, and it runs up to `steadyCatchUp` longer.
    public static func animateSteadily(
        duration: TimeInterval,
        curve: TimingCurve = .linear,
        _ update: @escaping (SKNode, CGFloat) -> Void
    ) -> SKAction {
        guard duration > 0 else { return .run { } }
        let total = duration + steadyCatchUp
        let frameStep = steadyFrameStep
        var played: TimeInterval = 0
        var last: CGFloat = 0
        return .customAction(withDuration: total) { node, elapsed in
            let step = min(TimeInterval(elapsed - last), frameStep)
            last = elapsed
            played = elapsed >= CGFloat(total) ? duration : min(duration, played + step)
            update(node, curve(CGFloat(played / duration)))
        }
    }

    /// Moves and scales together, as a panel zooms out of a touch or back
    /// into it. Entrances go `steadily`, since a new panel's first frame is
    /// slow; that action runs on a little past `duration`.
    public static func zoom(
        from start: (position: CGPoint, scale: CGFloat),
        to end: (position: CGPoint, scale: CGFloat),
        duration: TimeInterval,
        curve: TimingCurve,
        steadily: Bool = false
    ) -> SKAction {
        let update: (SKNode, CGFloat) -> Void = { node, progress in
            node.position = progress.lerp(start.position, end.position)
            node.setScale(progress.lerp(start.scale, end.scale))
        }
        return steadily
            ? .animateSteadily(duration: duration, curve: curve, update)
            : .animate(duration: duration, curve: curve, update)
    }

    /// A looping two-way animation, like a CSS `infinite` keyframe at 50%:
    /// bobs, breathing, pulses.
    public static func pingPong(
        duration: TimeInterval,
        _ update: @escaping (SKNode, CGFloat) -> Void
    ) -> SKAction {
        let half = duration / 2
        return .repeatForever(.sequence([
            .animate(duration: half, curve: .easeInOut, update),
            .animate(duration: half, curve: .easeInOut) { node, progress in update(node, 1 - progress) },
        ]))
    }
}
