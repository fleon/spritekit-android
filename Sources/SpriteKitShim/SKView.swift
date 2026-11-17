#if SPRITEKIT_SHIM
import Foundation

/// Hears from the view before each frame it would draw.
///
/// A game may have one that notes when every frame renders, or one that
/// takes the view's turn at SpriteKit while a scene renders off screen on a
/// thread of its own, passing each frame on to whichever delegate the view
/// had before it.
///
/// On Apple the method is an Objective-C optional requirement, and a
/// forwarding delegate asks it the way one asks those:
///
///     forwarded?.view?(view, shouldRenderAtTime: time)
///
/// There is no Objective-C on Android, so no optional requirements. The
/// method is an ordinary requirement with a default that renders, and the
/// optional spelling is kept by a property, also named `view`, holding a
/// value that can be called with the method's own labels
/// (`callAsFunction`). A delegate that implements the method is asked it; one
/// that does not answers true, which is also what `?? true` makes of
/// SpriteKit's nil. A conforming class's own `view` property, as a
/// forwarding delegate may have, takes precedence over this one inside that
/// class.
public protocol SKViewDelegate: NSObjectProtocol {
    /// Whether the view draws the frame at `time`. Returning false skips the
    /// whole frame: no update, no actions, nothing drawn.
    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool
}

extension SKViewDelegate {
    public func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool { true }

    /// `delegate.view?(view, shouldRenderAtTime:)`: see the protocol.
    public var view: SKViewDelegateQuery? { SKViewDelegateQuery(delegate: self) }
}

/// The delegate's method, held so it can be called as `view?(…)`.
public struct SKViewDelegateQuery {
    let delegate: any SKViewDelegate

    public func callAsFunction(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        delegate.view(view, shouldRenderAtTime: time)
    }
}

/// The host surface. On Android the shell's GLES 3 context stands behind it;
/// the shim keeps what the game reads from a view, and turns a scene (or, in
/// a transition, two) into one frame's `DrawList`.
///
/// `bounds` is in points, as UIKit's are, and `contentScaleFactor` is the
/// pixels in each. A game sizes its scenes from `bounds`, so pixels there
/// would make every scene three times too big.
open class SKView: UIView {
    open private(set) var scene: SKScene?

    /// How often the view draws at most. The shell's frame loop asks
    /// `shouldRender(atTime:)`, which keeps to it.
    public var preferredFramesPerSecond: Int = 60

    /// One refresh of the display, once the shell knows it: a frame lets
    /// through half a refresh early, so jitter never holds one back.
    public var refreshInterval: TimeInterval?

    /// A paused view draws nothing new: what is on screen stays there, as
    /// SpriteKit holds its last frame.
    public var isPaused: Bool = false

    /// Points-to-pixels, as the display reports it.
    public var contentScaleFactor: CGFloat = 3

    open weak var delegate: (any SKViewDelegate)?

    /// Carried: the GLES renderer always draws on the frame thread, so a
    /// game turning it off changes nothing.
    public var isAsynchronous = true

    /// Always so here: the draw list is ordered by depth alone (README,
    /// "a frame is a value"), which is what this asks SpriteKit for.
    public var ignoresSiblingOrder = true
    /// Sprites wholly outside what the view shows are left out of the frame
    /// (`DrawList(scene:transform:culling:)`), as SpriteKit culls them.
    public var shouldCullNonVisibleNodes = true

    /// How fast transitions play: the runtime's own, for filming a 0.1-second
    /// fade on an emulator that draws a few frames a second
    /// (`debug.<app>.transitionslowdown`). Not SpriteKit API.
    public var transitionSpeed: Double = 1

    /// A transition under way: the scene leaving, still drawn and still in
    /// the view until it ends, and how far through it is.
    private final class Flight {
        let outgoing: SKScene
        let transition: SKTransition
        var elapsed: TimeInterval = 0

        init(outgoing: SKScene, transition: SKTransition) {
            self.outgoing = outgoing
            self.transition = transition
        }

        var progress: CGFloat {
            transition.duration > 0 ? CGFloat(elapsed / transition.duration) : 1
        }
    }

    private var flight: Flight?

    /// When the frame rate last let a frame through, for
    /// `preferredFramesPerSecond`.
    private var lastFired: TimeInterval?

    /// Sizes the view for a drawable of `pixels` on a display of
    /// `displayScale` pixels per density-independent pixel (Android's dp,
    /// `SDL_GetWindowDisplayScale`): a point is one of those, as an iOS
    /// point is one of its screen's, so a 420 dpi phone's 1080 × 2400 is
    /// 411 × 914 points, near an iPhone's, and the game's own layout sizes
    /// every popup and sheet as it does there. The art's export scale has
    /// no say: its textures are simply drawn at this many pixels a point.
    public func resize(drawable pixels: CGSize, displayScale: CGFloat) {
        let scale = displayScale > 0 ? displayScale : contentScaleFactor
        contentScaleFactor = scale
        bounds = CGRect(x: 0, y: 0, width: pixels.width / scale, height: pixels.height / scale)
    }

    public convenience init(bounds: CGRect) {
        self.init(frame: bounds)
        self.bounds = bounds
    }

    /// UIKit's: a view as big as `frame`, its own space at the origin.
    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    /// Whether a transition is playing.
    public var isTransitioning: Bool { flight != nil }

    // MARK: Presenting

    /// Swaps scenes at once. The scene leaving hears `willMove(from:)` and
    /// leaves the view before the new one hears `didMove(to:)`.
    open func presentScene(_ scene: SKScene?) {
        guard scene !== self.scene else { return }
        land()
        if let current = self.scene {
            current.willMove(from: self)
            current.view = nil
        }
        self.scene = scene
        guard let scene else { return }
        scene.view = self
        scene.actionClockStarted = false
        scene.didMove(to: self)
    }

    /// Swaps scenes through `transition`.
    ///
    /// As in SpriteKit, the swap itself happens now: the scene leaving hears
    /// `willMove(from:)`, `scene` becomes the view's scene and hears
    /// `didMove(to:)`, all before this returns — which is why the game's
    /// entrances wait out `sceneRevealDelay` before they play. The scene
    /// leaving stays in the view, drawn and (unless the transition pauses
    /// it) running, until the transition ends; then it leaves.
    ///
    /// A scene presented while a transition is still playing ends that one
    /// where it stands: the scene it was taking away leaves, and the one it
    /// was bringing in is the one this takes away.
    open func presentScene(_ scene: SKScene, transition: SKTransition) {
        guard scene !== self.scene else { return }
        land()
        let outgoing = self.scene
        outgoing?.willMove(from: self)
        self.scene = scene
        scene.view = self
        scene.actionClockStarted = false
        if let outgoing {
            if transition.duration > 0 {
                flight = Flight(outgoing: outgoing, transition: transition)
            } else {
                outgoing.view = nil
            }
        }
        // Last, so a scene that presents another as it arrives finds this
        // transition already under way and ends it properly.
        scene.didMove(to: self)
    }

    /// Ends the transition under way, if any: its outgoing scene leaves.
    private func land() {
        guard let flight else { return }
        self.flight = nil
        if flight.outgoing !== scene { flight.outgoing.view = nil }
    }

    // MARK: Frames

    /// Whether the frame at `time` should be drawn: not while paused, no
    /// sooner than `preferredFramesPerSecond` allows, and only if the
    /// delegate agrees. The shell asks before every frame, and skips the
    /// frame — update, actions and drawing — when the answer is no.
    ///
    /// The frame rate is kept with a quarter of a frame's slack, or half a
    /// refresh if less (`refreshInterval`), so a 60 Hz display's jitter
    /// never drops a frame at 60, 30 lands on every other one, and on a
    /// 120 Hz display 30 every fourth and 40 every third.
    public func shouldRender(atTime time: TimeInterval) -> Bool {
        guard !isPaused else { return false }
        // With a fixed step every frame is one step: the step is the rate.
        if preferredFramesPerSecond > 0, MediaTime.fixedStep == nil, let last = lastFired {
            let interval = 1 / TimeInterval(preferredFramesPerSecond)
            let slack = min(refreshInterval.map { $0 / 2 } ?? .infinity, interval / 4)
            guard time - last >= interval - slack else { return false }
        }
        // A display link at the preferred rate fires whatever the delegate
        // then says, so the rate counts from here.
        lastFired = time
        if let delegate, !delegate.view(self, shouldRenderAtTime: time) { return false }
        return true
    }

    /// One frame: each running scene's own update, then its actions, then
    /// one draw list of what the view shows, in the presented scene's
    /// coordinates (the projection the renderer sets up from it).
    open func tick(currentTime: TimeInterval, delta: TimeInterval) -> DrawList {
        guard let scene, !isPaused else { return DrawList() }

        if let flight {
            flight.elapsed += delta * transitionSpeed
            if flight.elapsed >= flight.transition.duration {
                land()
                advance(scene, currentTime: currentTime, delta: delta)
            } else {
                if !flight.transition.pausesOutgoingScene {
                    advance(flight.outgoing, currentTime: currentTime, delta: delta)
                }
                if !flight.transition.pausesIncomingScene {
                    advance(scene, currentTime: currentTime, delta: delta)
                }
            }
        } else {
            advance(scene, currentTime: currentTime, delta: delta)
        }

        // Either scene may have presented another meanwhile.
        guard let shown = self.scene else { return DrawList() }
        guard let flight else { return Self.picture(of: shown, culling: shouldCullNonVisibleNodes) }
        return compose(flight, incoming: shown)
    }

    /// A scene's update, then its actions, as SpriteKit times them (measured
    /// on a Mac's `SKView`): a scene's first frame after it's presented
    /// counts no time, however long it took, and nor does any frame longer
    /// than `longestCountedFrame`, which isn't clamped but dropped. So a
    /// scene that took a while to present doesn't spend its first frame
    /// running out a wait its nodes haven't had a frame of yet (a snapshot
    /// taken after a short wait came out before they drew).
    private func advance(_ scene: SKScene, currentTime: TimeInterval, delta: TimeInterval) {
        scene.update(currentTime)
        let counted = scene.actionClockStarted && delta <= Self.longestCountedFrame ? delta : 0
        scene.actionClockStarted = true
        scene.tickActions(counted)
    }

    /// The longest frame whose time actions count: a 0.98 s frame advances
    /// them in full on SpriteKit, a 1.03 s one not at all.
    static let longestCountedFrame: TimeInterval = 1

    // MARK: Composing

    /// A scene as the view shows it, in its own coordinates as they are
    /// with no camera (`viewVisibleFrame`'s): its background over the whole
    /// view, then its contents through its camera.
    /// With `culling`, what lies wholly outside the view is left out: a
    /// transition moves a scene's picture after this, so it's culled by the
    /// scene's own frame, which keeps all that can show.
    static func picture(of scene: SKScene, culling: Bool = false) -> DrawList {
        var list = DrawList()
        if scene.backgroundColor.alpha > 0 {
            list.commands.append(.sprite(fill(scene.viewVisibleFrame, colour: scene.backgroundColor, alpha: 1)))
        }
        list.commands += DrawList(scene: scene, transform: scene.cameraTransform, culling: culling ? scene.viewVisibleFrame : nil).commands
        return list
    }

    /// Both scenes, as `flight` draws them this far through, in the incoming
    /// scene's coordinates.
    private func compose(_ flight: Flight, incoming: SKScene) -> DrawList {
        let frame = incoming.viewVisibleFrame
        let outgoingFrame = flight.outgoing.viewVisibleFrame
        // The outgoing scene's frame laid over the incoming one's: the same
        // view, whatever size and anchor each scene has.
        let across = CGAffineTransform(translationX: -outgoingFrame.minX, y: -outgoingFrame.minY)
            .concatenating(CGAffineTransform(
                scaleX: outgoingFrame.width > 0 ? frame.width / outgoingFrame.width : 1,
                y: outgoingFrame.height > 0 ? frame.height / outgoingFrame.height : 1
            ))
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))

        var list = DrawList()
        for layer in flight.transition.frame(at: flight.progress).layers {
            switch layer {
            case let .outgoing(offset, alpha):
                list.commands += Self.layer(
                    Self.picture(of: flight.outgoing, culling: shouldCullNonVisibleNodes), of: flight.outgoing,
                    placed: across, offset: offset, alpha: alpha, in: frame
                )
            case let .incoming(offset, alpha):
                list.commands += Self.layer(
                    Self.picture(of: incoming, culling: shouldCullNonVisibleNodes), of: incoming,
                    placed: .identity, offset: offset, alpha: alpha, in: frame
                )
            case let .colour(colour, alpha):
                guard alpha > 0 else { continue }
                list.commands.append(.sprite(Self.fill(frame, colour: colour, alpha: alpha)))
            }
        }
        return list
    }

    /// One scene's picture, moved into place and shifted by `offset` views,
    /// and drawn as a single picture when it is translucent — so a scene's
    /// overlapping nodes do not show through one another as it fades.
    private static func layer(
        _ picture: DrawList,
        of scene: SKScene,
        placed: CGAffineTransform,
        offset: CGPoint,
        alpha: CGFloat,
        in frame: CGRect
    ) -> [DrawList.Command] {
        guard alpha > 0 else { return [] }
        let moved = picture.transformed(by: placed.concatenating(
            CGAffineTransform(translationX: offset.x * frame.width, y: offset.y * frame.height)
        ))
        guard alpha < 1 else { return moved.commands }
        return [.effect(DrawList.Effect(
            bounds: frame, transform: .identity, shader: nil, alpha: alpha,
            blendMode: .alpha, shouldRasterize: false, owner: ObjectIdentifier(scene),
            rasterGeneration: 0, contentsDigest: 0, contents: moved
        ))]
    }

    /// A flat colour over `frame`.
    private static func fill(_ frame: CGRect, colour: SKColor, alpha: CGFloat) -> DrawList.Sprite {
        DrawList.Sprite(
            transform: CGAffineTransform(translationX: frame.minX, y: frame.minY),
            size: frame.size,
            anchorPoint: .zero,
            texture: nil,
            textureRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            color: colour,
            colorBlendFactor: 1,
            alpha: alpha,
            blendMode: .alpha,
            shader: nil,
            attributeValues: [:]
        )
    }
}

extension DrawList {
    /// The same list drawn through `transform` as well: every top-level
    /// command moves, and what nests inside an effect or crop moves with it.
    func transformed(by transform: CGAffineTransform) -> DrawList {
        guard transform != .identity else { return self }
        var list = self
        list.commands = commands.map { command in
            switch command {
            case var .sprite(sprite):
                sprite.transform = sprite.transform.concatenating(transform)
                return .sprite(sprite)
            case var .shape(shape):
                shape.transform = shape.transform.concatenating(transform)
                return .shape(shape)
            case var .label(label):
                label.transform = label.transform.concatenating(transform)
                return .label(label)
            case var .effect(effect):
                effect.transform = effect.transform.concatenating(transform)
                return .effect(effect)
            case var .crop(crop):
                crop.transform = crop.transform.concatenating(transform)
                return .crop(crop)
            }
        }
        return list
    }
}

#endif
