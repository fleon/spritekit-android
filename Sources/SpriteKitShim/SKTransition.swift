#if SPRITEKIT_SHIM
import Foundation

public enum SKTransitionDirection: Int, Sendable {
    case up, down, right, left
}

/// How the view goes from one scene to the next.
///
/// `fade(withDuration:)`, both scenes left running, and the other kinds
/// SpriteKit offers that draw with nothing but the two scenes and a colour
/// are here; the 3D ones (doorways, flips, CIFilter transitions) are not.
///
/// Every kind moves linearly in time, and draws each scene whole — its
/// background, its contents through its own camera — as `SKView` composes
/// them (`SKView.tick`).
open class SKTransition {
    enum Kind {
        /// To `colour` over the first half, from it over the second.
        case fade(SKColor)
        /// The incoming scene over the outgoing one, fading in.
        case crossFade
        /// Both slide the same way, the incoming one pushing the other out.
        case push(SKTransitionDirection)
        /// The incoming one slides in over the outgoing one.
        case moveIn(SKTransitionDirection)
        /// The outgoing one slides away off the incoming one.
        case reveal(SKTransitionDirection)
    }

    let kind: Kind
    let duration: TimeInterval

    /// Whether the scene going away stops while the transition plays. On by
    /// default, as SpriteKit has it.
    open var pausesOutgoingScene = true
    /// Whether the scene coming in waits for the transition to finish before
    /// it moves. On by default, as SpriteKit has it.
    open var pausesIncomingScene = true

    init(kind: Kind, duration: TimeInterval) {
        self.kind = kind
        self.duration = duration
    }

    open class func crossFade(withDuration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .crossFade, duration: sec)
    }

    /// Through black.
    open class func fade(withDuration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .fade(.black), duration: sec)
    }

    open class func fade(with color: SKColor, duration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .fade(color), duration: sec)
    }

    open class func push(with direction: SKTransitionDirection, duration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .push(direction), duration: sec)
    }

    open class func moveIn(with direction: SKTransitionDirection, duration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .moveIn(direction), duration: sec)
    }

    open class func reveal(with direction: SKTransitionDirection, duration sec: TimeInterval) -> SKTransition {
        SKTransition(kind: .reveal(direction), duration: sec)
    }
}

extension SKTransition {
    /// What a frame `progress` of the way through draws.
    struct Frame {
        enum Layer {
            /// A scene, shifted by `offset` of the view (1 is the view's
            /// whole width or height) and drawn at `alpha` as one picture.
            case outgoing(offset: CGPoint, alpha: CGFloat)
            case incoming(offset: CGPoint, alpha: CGFloat)
            /// A colour over the whole view.
            case colour(SKColor, alpha: CGFloat)
        }

        /// Back to front.
        var layers: [Layer]
    }

    func frame(at progress: CGFloat) -> Frame {
        let p = min(max(progress, 0), 1)
        switch kind {
        case let .fade(colour):
            // Out to the colour and back in from it, the colour opaque at the
            // middle, so neither scene shows through the other.
            return p < 0.5
                ? Frame(layers: [.outgoing(offset: .zero, alpha: 1), .colour(colour, alpha: p * 2)])
                : Frame(layers: [.incoming(offset: .zero, alpha: 1), .colour(colour, alpha: (1 - p) * 2)])
        case .crossFade:
            return Frame(layers: [.outgoing(offset: .zero, alpha: 1), .incoming(offset: .zero, alpha: p)])
        case let .push(direction):
            let way = Self.unit(direction)
            return Frame(layers: [
                .outgoing(offset: way * p, alpha: 1),
                .incoming(offset: way * (p - 1), alpha: 1),
            ])
        case let .moveIn(direction):
            return Frame(layers: [
                .outgoing(offset: .zero, alpha: 1),
                .incoming(offset: Self.unit(direction) * (p - 1), alpha: 1),
            ])
        case let .reveal(direction):
            return Frame(layers: [
                .incoming(offset: .zero, alpha: 1),
                .outgoing(offset: Self.unit(direction) * p, alpha: 1),
            ])
        }
    }

    /// The way a direction moves things, a view's width or height at a time.
    private static func unit(_ direction: SKTransitionDirection) -> CGPoint {
        switch direction {
        case .up: return CGPoint(x: 0, y: 1)
        case .down: return CGPoint(x: 0, y: -1)
        case .right: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: -1, y: 0)
        }
    }
}

private func * (point: CGPoint, scale: CGFloat) -> CGPoint {
    CGPoint(x: point.x * scale, y: point.y * scale)
}

#endif
