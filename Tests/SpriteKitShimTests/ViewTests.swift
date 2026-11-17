import Foundation
import Testing
@testable import SpriteKitShim

// The view surface: the camera the scene is drawn from, transitions between
// scenes, and the delegate the frame loop asks before each frame. All of it
// is the view turning scenes into one frame's DrawList, so none of it needs
// a device.

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.0001) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

/// Where the first sprite command in `list` puts its node's origin.
private func origin(of list: DrawList, at index: Int = 0) -> CGPoint? {
    guard list.commands.indices.contains(index), case let .sprite(sprite) = list.commands[index] else { return nil }
    return CGPoint.zero.applying(sprite.transform)
}

@Suite("Camera")
struct CameraTests {
    /// A 200 x 100 scene in a 200 x 100 view: scene points are view points.
    private func scene(anchor: CGPoint = .zero) -> (SKView, SKScene) {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let scene = SKScene(size: CGSize(width: 200, height: 100))
        scene.anchorPoint = anchor
        scene.backgroundColor = .clear
        view.presentScene(scene)
        return (view, scene)
    }

    private func marker(at point: CGPoint) -> SKSpriteNode {
        let node = SKSpriteNode(color: .red, size: CGSize(width: 2, height: 2))
        node.position = point
        return node
    }

    @Test("Without a camera the scene draws as it stands")
    func none() {
        let (_, scene) = scene()
        #expect(scene.cameraTransform == .identity)
        let camera = SKCameraNode()
        // Set, but not in the scene's tree: ignored, as SpriteKit ignores it.
        scene.camera = camera
        #expect(scene.cameraTransform == .identity)
    }

    @Test("The camera's position draws in the middle of the view, whatever the anchor")
    func centred() {
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
            let (view, scene) = scene(anchor: anchor)
            let camera = SKCameraNode()
            camera.position = CGPoint(x: 300, y: -40)
            scene.addChild(camera)
            scene.camera = camera
            scene.addChild(marker(at: CGPoint(x: 300, y: -40)))
            let list = view.tick(currentTime: 0, delta: 0)
            #expect(close(origin(of: list) ?? .zero, CGPoint(x: scene.visibleFrame.midX, y: scene.visibleFrame.midY)))
            // And it is the middle of the view, in the view's own points.
            #expect(close(scene.convertPoint(toView: CGPoint(x: 300, y: -40)), CGPoint(x: 100, y: 50)))
        }
    }

    @Test("The camera's scale and rotation are undone")
    func scaledAndTurned() {
        let (view, scene) = scene()
        let camera = SKCameraNode()
        camera.position = CGPoint(x: 50, y: 50)
        camera.setScale(2)
        scene.addChild(camera)
        scene.camera = camera
        scene.addChild(marker(at: CGPoint(x: 70, y: 50)))
        // Twice as much shows, so 20 points off the camera is 10 on screen.
        var list = view.tick(currentTime: 0, delta: 0)
        #expect(close(origin(of: list) ?? .zero, CGPoint(x: 110, y: 50)))

        camera.setScale(1)
        camera.zRotation = .pi / 2
        // Turned a quarter left, the camera sees the scene a quarter right:
        // a point to the camera's right draws below the middle.
        list = view.tick(currentTime: 0, delta: 0)
        #expect(close(origin(of: list) ?? .zero, CGPoint(x: 100, y: 30)))
    }

    @Test("What hangs off the camera stays put on the screen")
    func hud() {
        let (view, scene) = scene()
        let camera = SKCameraNode()
        scene.addChild(camera)
        scene.camera = camera
        let hud = marker(at: CGPoint(x: -80, y: 40))
        camera.addChild(hud)
        for (position, scale, turn) in [(CGPoint(x: 0, y: 0), 1.0, 0.0), (CGPoint(x: 500, y: 90), 3.0, 1.2)] {
            camera.position = position
            camera.setScale(CGFloat(scale))
            camera.zRotation = CGFloat(turn)
            let list = view.tick(currentTime: 0, delta: 0)
            #expect(close(origin(of: list) ?? .zero, CGPoint(x: 20, y: 90)))
        }
    }

    @Test("A point in the view maps back through the camera")
    func touches() {
        let (_, scene) = scene()
        let camera = SKCameraNode()
        camera.position = CGPoint(x: 1000, y: 1000)
        camera.setScale(0.5)
        scene.addChild(camera)
        scene.camera = camera
        // The view's middle is the camera; its top left corner is half the
        // view's size away, halved again by the zoom, and y counts down.
        #expect(close(scene.convertPoint(fromView: CGPoint(x: 100, y: 50)), CGPoint(x: 1000, y: 1000)))
        #expect(close(scene.convertPoint(fromView: CGPoint(x: 0, y: 0)), CGPoint(x: 950, y: 1025)))
        for point in [CGPoint(x: 3, y: 97), CGPoint(x: 140, y: 12)] {
            #expect(close(scene.convertPoint(toView: scene.convertPoint(fromView: point)), point))
        }
    }

    @Test("A touch lands on the node the camera shows there")
    func hit() {
        let (_, scene) = scene()
        let camera = SKCameraNode()
        camera.position = CGPoint(x: 400, y: 0)
        scene.addChild(camera)
        scene.camera = camera
        final class Button: SKSpriteNode {
            var taps = 0
            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { taps += 1 }
        }
        let button = Button(color: .red, size: CGSize(width: 20, height: 20))
        button.isUserInteractionEnabled = true
        button.position = CGPoint(x: 400, y: 0)
        scene.addChild(button)
        let point = scene.convertPoint(fromView: CGPoint(x: 100, y: 50))
        scene.deliverTouch(phase: .began, at: point, timestamp: 0)
        #expect(button.taps == 1)
    }

    @Test("contains and containedNodeSet test against the camera's view")
    func containment() {
        let (_, scene) = scene()
        let camera = SKCameraNode()
        camera.position = CGPoint(x: 1000, y: 0)
        scene.addChild(camera)
        scene.camera = camera
        let near = marker(at: CGPoint(x: 1050, y: 30))
        let far = marker(at: CGPoint(x: 100, y: 50))
        let edge = marker(at: CGPoint(x: 1100.5, y: 0))
        scene.addChild(near)
        scene.addChild(far)
        scene.addChild(edge)
        #expect(camera.contains(near))
        #expect(!camera.contains(far))
        #expect(camera.contains(edge))
        let seen = camera.containedNodeSet()
        #expect(seen.contains(near) && seen.contains(edge) && !seen.contains(far))
        // A node from another scene is never in view.
        #expect(!camera.contains(marker(at: CGPoint(x: 1000, y: 0))))
    }
}

// MARK: - Transitions

/// A scene that writes what happens to it into a shared log.
final class LoggingScene: SKScene {
    let label: String
    let log: Log
    var updates = 0

    final class Log {
        var entries: [String] = []
    }

    init(_ label: String, log: Log, size: CGSize = CGSize(width: 200, height: 100)) {
        self.label = label
        self.log = log
        super.init(size: size)
        backgroundColor = .clear
    }

    override func didMove(to view: SKView) {
        log.entries.append("\(label).didMove scene=\((view.scene as? LoggingScene)?.label ?? "-")")
    }

    override func willMove(from view: SKView) {
        log.entries.append("\(label).willMove")
    }

    override func update(_ currentTime: TimeInterval) {
        updates += 1
    }
}

@Suite("Transitions")
struct TransitionTests {
    private func view() -> SKView {
        SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    /// A scene with one marker sprite in it, so its picture can be told apart.
    private func scene(_ label: String, log: LoggingScene.Log, colour: SKColor) -> LoggingScene {
        let scene = LoggingScene(label, log: log)
        scene.addChild(SKSpriteNode(color: colour, size: CGSize(width: 10, height: 10)))
        return scene
    }

    /// Each command's colour and alpha, nesting flattened, in draw order.
    private func colours(_ list: DrawList) -> [(SKColor, CGFloat)] {
        list.commands.flatMap { command -> [(SKColor, CGFloat)] in
            switch command {
            case let .sprite(sprite): return [(sprite.color, sprite.alpha)]
            case let .effect(effect): return colours(effect.contents).map { ($0.0, $0.1 * effect.alpha) }
            default: return []
            }
        }
    }

    @Test("A transition swaps the scenes at once, in SpriteKit's order")
    func order() {
        let log = LoggingScene.Log()
        let view = view()
        let a = scene("A", log: log, colour: .red)
        let b = scene("B", log: log, colour: .blue)
        view.presentScene(a)
        view.presentScene(b, transition: .fade(withDuration: 1))
        #expect(log.entries == ["A.didMove scene=A", "A.willMove", "B.didMove scene=B"])
        #expect(view.scene === b)
        // The scene leaving is still drawn, so it is still in the view.
        #expect(a.view === view)
        #expect(view.isTransitioning)
        _ = view.tick(currentTime: 1, delta: 1)
        #expect(!view.isTransitioning)
        #expect(a.view == nil)
        #expect(b.view === view)
    }

    @Test("A fade goes to its colour over the first half and back over the second")
    func fade() {
        let log = LoggingScene.Log()
        let view = view()
        view.presentScene(scene("A", log: log, colour: .red))
        view.presentScene(scene("B", log: log, colour: .blue), transition: .fade(with: .green, duration: 1))

        func frame(_ delta: TimeInterval) -> [(SKColor, CGFloat)] {
            colours(view.tick(currentTime: 0, delta: delta))
        }
        let quarter = frame(0.25)
        #expect(quarter.count == 2)
        #expect(quarter[0].0 === SKColor.red && quarter[0].1 == 1)
        #expect(quarter[1].0 === SKColor.green && abs(quarter[1].1 - 0.5) < 1e-9)

        let middle = frame(0.25)
        #expect(middle[0].0 === SKColor.blue)
        #expect(middle[1].0 === SKColor.green && abs(middle[1].1 - 1) < 1e-9)

        let late = frame(0.25)
        #expect(late[0].0 === SKColor.blue)
        #expect(late[1].0 === SKColor.green && abs(late[1].1 - 0.5) < 1e-9)

        let done = frame(0.25)
        #expect(done.count == 1)
        #expect(done[0].0 === SKColor.blue && done[0].1 == 1)
    }

    @Test("fade(withDuration:) fades through black")
    func black() {
        guard case let .fade(colour) = SKTransition.fade(withDuration: 0.1).kind else {
            Issue.record("not a fade")
            return
        }
        #expect(colour.red == 0 && colour.green == 0 && colour.blue == 0 && colour.alpha == 1)
    }

    @Test("A crossfade draws the incoming scene over the outgoing one as one picture")
    func crossFade() {
        let log = LoggingScene.Log()
        let view = view()
        view.presentScene(scene("A", log: log, colour: .red))
        view.presentScene(scene("B", log: log, colour: .blue), transition: .crossFade(withDuration: 1))
        let list = view.tick(currentTime: 0, delta: 0.25)
        #expect(list.commands.count == 2)
        guard case .sprite = list.commands[0], case let .effect(effect) = list.commands[1] else {
            Issue.record("expected the outgoing sprite, then the incoming scene as one effect")
            return
        }
        #expect(abs(effect.alpha - 0.25) < 1e-9)
        #expect(effect.shader == nil)
        #expect(effect.bounds == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test("A push slides both scenes a view's width")
    func push() {
        let log = LoggingScene.Log()
        let view = view()
        view.presentScene(scene("A", log: log, colour: .red))
        view.presentScene(scene("B", log: log, colour: .blue), transition: .push(with: .left, duration: 1))
        let list = view.tick(currentTime: 0, delta: 0.25)
        // Moving left: the old scene a quarter off to the left, the new one
        // three quarters off to the right.
        #expect(close(origin(of: list, at: 0) ?? .zero, CGPoint(x: -50, y: 0)))
        #expect(close(origin(of: list, at: 1) ?? .zero, CGPoint(x: 150, y: 0)))
    }

    @Test("The two scenes meet in the view, whatever their anchors")
    func anchors() {
        let log = LoggingScene.Log()
        let view = view()
        let a = scene("A", log: log, colour: .red)
        let b = scene("B", log: log, colour: .blue)
        // The loading screen is anchored in its middle; a level is not.
        a.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        view.presentScene(a)
        view.presentScene(b, transition: .fade(withDuration: 1))
        let list = view.tick(currentTime: 0, delta: 0.1)
        // A's marker is at its origin, the view's middle — which is (100, 50)
        // in B's coordinates.
        #expect(close(origin(of: list) ?? .zero, CGPoint(x: 100, y: 50)))
    }

    @Test("The pause flags decide which scenes run while it plays")
    func pauses() {
        for (pausesOut, pausesIn) in [(true, true), (false, false), (true, false)] {
            let log = LoggingScene.Log()
            let view = view()
            let a = LoggingScene("A", log: log)
            let b = LoggingScene("B", log: log)
            let spin = SKAction.rotate(byAngle: 1, duration: 1)
            a.run(spin)
            b.run(spin)
            view.presentScene(a)
            let transition = SKTransition.fade(withDuration: 1)
            transition.pausesOutgoingScene = pausesOut
            transition.pausesIncomingScene = pausesIn
            view.presentScene(b, transition: transition)
            for _ in 0 ..< 3 { _ = view.tick(currentTime: 0, delta: 0.25) }
            #expect(a.updates == (pausesOut ? 0 : 3))
            #expect(b.updates == (pausesIn ? 0 : 3))
            // Each scene's first frame in the view counts no time.
            #expect(abs(a.zRotation - (pausesOut ? 0 : 0.5)) < 1e-9)
            #expect(abs(b.zRotation - (pausesIn ? 0 : 0.5)) < 1e-9)
            // Once it lands, only the new scene runs, paused or not before.
            _ = view.tick(currentTime: 0, delta: 0.25)
            _ = view.tick(currentTime: 0, delta: 0.25)
            #expect(a.updates == (pausesOut ? 0 : 3))
            #expect(b.updates == (pausesIn ? 2 : 5))
        }
    }

    @Test("A scene presented mid-transition ends it where it stands")
    func interrupted() {
        let log = LoggingScene.Log()
        let view = view()
        let a = LoggingScene("A", log: log)
        let b = LoggingScene("B", log: log)
        let c = LoggingScene("C", log: log)
        view.presentScene(a)
        view.presentScene(b, transition: .fade(withDuration: 1))
        _ = view.tick(currentTime: 0, delta: 0.25)
        view.presentScene(c, transition: .fade(withDuration: 1))
        #expect(log.entries.suffix(2) == ["B.willMove", "C.didMove scene=C"])
        #expect(a.view == nil)
        #expect(b.view === view)
        _ = view.tick(currentTime: 0, delta: 1)
        #expect(b.view == nil && c.view === view)
    }

    @Test("A scene that presents another as it arrives ends the transition that brought it")
    func chained() {
        let log = LoggingScene.Log()
        let view = view()
        final class Bounce: SKScene {
            var next: SKScene?
            override func didMove(to view: SKView) {
                if let next { view.presentScene(next, transition: .fade(withDuration: 1)) }
            }
        }
        let a = LoggingScene("A", log: log)
        let bounce = Bounce(size: CGSize(width: 200, height: 100))
        let c = LoggingScene("C", log: log)
        bounce.next = c
        view.presentScene(a)
        view.presentScene(bounce, transition: .fade(withDuration: 1))
        #expect(view.scene === c)
        #expect(a.view == nil)
        #expect(bounce.view === view)
    }

    @Test("A zero-length transition is a plain swap")
    func instant() {
        let log = LoggingScene.Log()
        let view = view()
        let a = LoggingScene("A", log: log)
        let b = LoggingScene("B", log: log)
        view.presentScene(a)
        view.presentScene(b, transition: .fade(withDuration: 0))
        #expect(!view.isTransitioning)
        #expect(a.view == nil)
    }

    @Test("The scene's background is drawn under it, over the whole view")
    func background() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 300, height: 100))
        let scene = SKScene(size: CGSize(width: 200, height: 100))
        scene.backgroundColor = .red
        view.presentScene(scene)
        let list = view.tick(currentTime: 0, delta: 0)
        guard case let .sprite(fill) = list.commands.first else {
            Issue.record("no background")
            return
        }
        #expect(fill.color === SKColor.red)
        #expect(CGRect(origin: CGPoint.zero.applying(fill.transform), size: fill.size) == scene.visibleFrame)
        // Aspect fill on a wider view fills its width and loses some height,
        // shared top and bottom.
        let shown = scene.visibleFrame
        #expect(close(shown.origin, CGPoint(x: 0, y: 50.0 / 3), 1e-9))
        #expect(abs(shown.width - 200) < 1e-9 && abs(shown.height - 200.0 / 3) < 1e-9)
    }
}

// MARK: - The delegate

/// The shape of a game's forwarding view delegate, where it touches the
/// view: its own `view` property, a `forwarded` delegate, and
/// the Objective-C optional spelling it asks that delegate with.
final class ForwardingDelegate: NSObject, SKViewDelegate {
    private weak var view: SKView?
    private weak var forwarded: (any SKViewDelegate)?
    var asked = 0

    init(view: SKView) {
        self.view = view
        forwarded = view.delegate
        super.init()
        view.delegate = self
    }

    func end() {
        guard let view, view.delegate === self else { return }
        view.delegate = forwarded
    }

    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        asked += 1
        return forwarded?.view?(view, shouldRenderAtTime: time) ?? true
    }
}

/// Renders every other frame it is asked about.
final class AlternatingDelegate: NSObject, SKViewDelegate {
    var times: [TimeInterval] = []

    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        times.append(time)
        return times.count % 2 == 0
    }
}

/// Implements nothing: SpriteKit's optional method left out.
final class SilentDelegate: NSObject, SKViewDelegate {}

@Suite("View delegate")
struct ViewDelegateTests {
    private let frame = 1.0 / 60

    @Test("The delegate is asked before each frame and can skip it")
    func gating() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = AlternatingDelegate()
        view.delegate = delegate
        let answers = (1 ... 4).map { view.shouldRender(atTime: Double($0) * frame) }
        #expect(answers == [false, true, false, true])
        #expect(delegate.times.count == 4)
    }

    @Test("A paused view draws nothing new and asks nobody")
    func paused() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = AlternatingDelegate()
        view.delegate = delegate
        view.isPaused = true
        #expect(!view.shouldRender(atTime: 1))
        #expect(delegate.times.isEmpty)
    }

    @Test("preferredFramesPerSecond keeps to its rate on a faster display")
    func frameRate() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = AlternatingDelegate()
        view.preferredFramesPerSecond = 30
        // A 60 Hz display, a little jittery.
        let jitter = [0.0, 0.0008, -0.0006, 0.0011, -0.0009, 0.0004, 0.0, -0.001]
        let rendered = jitter.enumerated().map { view.shouldRender(atTime: Double($0.offset) * frame + $0.element) }
        #expect(rendered == [true, false, true, false, true, false, true, false])
        // At 60 every frame of the same display draws.
        view.preferredFramesPerSecond = 60
        let all = jitter.enumerated().map { view.shouldRender(atTime: 1 + Double($0.offset) * frame + $0.element) }
        #expect(all.allSatisfy { $0 })
        // Only frames the rate lets through reach the delegate.
        view.delegate = delegate
        view.preferredFramesPerSecond = 30
        _ = (0 ..< 4).map { view.shouldRender(atTime: 2 + Double($0) * frame) }
        #expect(delegate.times.count == 2)
    }

    @Test("On a 120 Hz display 40 lands on every third refresh and 30 on every fourth")
    func frameRateOn120Hz() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let refresh = 1.0 / 120
        view.refreshInterval = refresh
        let jitter = [0.0, 0.0004, -0.0003, 0.0005, -0.0004, 0.0002, 0.0, -0.0005, 0.0003, -0.0002, 0.0004, 0.0, 0.0001]
        view.preferredFramesPerSecond = 40
        let forty = jitter.enumerated().map { view.shouldRender(atTime: Double($0.offset) * refresh + $0.element) }
        #expect(forty.enumerated().allSatisfy { $0.element == ($0.offset % 3 == 0) })
        view.preferredFramesPerSecond = 30
        let thirty = jitter.enumerated().map { view.shouldRender(atTime: 1 + Double($0.offset) * refresh + $0.element) }
        #expect(thirty.enumerated().allSatisfy { $0.element == ($0.offset % 4 == 0) })
    }

    @Test("A forwarding delegate asks the one before it")
    func forwarding() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let first = AlternatingDelegate()
        view.delegate = first
        let turns = ForwardingDelegate(view: view)
        #expect(view.delegate === turns)
        let answers = (1 ... 4).map { view.shouldRender(atTime: Double($0) * frame) }
        #expect(answers == [false, true, false, true])
        #expect(turns.asked == 4 && first.times.count == 4)
        turns.end()
        #expect(view.delegate === first)
    }

    @Test("A delegate that leaves the method out renders every frame")
    func optional() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let silent: (any SKViewDelegate)? = SilentDelegate()
        view.delegate = silent
        #expect(silent?.view?(view, shouldRenderAtTime: 0) == true)
        _ = ForwardingDelegate(view: view)
        #expect((1 ... 3).allSatisfy { view.shouldRender(atTime: Double($0) * frame) })
    }
}

@Suite("Action clock")
struct ActionClockTests {
    /// A scene built before it's presented, as the game builds its scenes
    /// off the main thread, with a 0.2 s wait on a parent and a child
    /// ticking under it: a snapshot taken once its rigs have moved.
    private func presented(_ waited: @escaping () -> Void, ticks: @escaping () -> Void) -> SKView {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let scene = SKScene(size: CGSize(width: 200, height: 100))
        let parent = SKNode()
        let child = SKNode()
        scene.addChild(parent)
        parent.addChild(child)
        child.run(.repeatForever(.customAction(withDuration: 1) { _, _ in ticks() }))
        parent.run(.sequence([.wait(forDuration: 0.2), .run(waited)]))
        view.presentScene(scene)
        return view
    }

    @Test("A scene's first frame counts no time, however long it took")
    func firstFrame() {
        var waited = false
        var ticks = 0
        var ticksWhenWaited = -1
        let view = presented({ waited = true; ticksWhenWaited = ticks }, ticks: { ticks += 1 })
        // The frame that presented it took half a second.
        _ = view.tick(currentTime: 0.5, delta: 0.5)
        #expect(!waited)
        // 0.2 s of frames after it: SpriteKit runs the wait out on the 13th.
        for frame in 1 ... 12 { _ = view.tick(currentTime: 0.5 + Double(frame) / 60, delta: 1.0 / 60) }
        #expect(!waited)
        _ = view.tick(currentTime: 0.5 + 13.0 / 60, delta: 1.0 / 60)
        #expect(waited)
        // The children had frames of their own before the wait ran out.
        #expect(ticksWhenWaited >= 12)
    }

    @Test("A frame longer than a second counts no time; one just under counts in full")
    func longFrames() {
        var waited = false
        let view = presented({ waited = true }, ticks: {})
        _ = view.tick(currentTime: 0, delta: 0)
        _ = view.tick(currentTime: 1.5, delta: 1.5)
        #expect(!waited)
        _ = view.tick(currentTime: 2.0, delta: 0.19)
        #expect(!waited)
        _ = view.tick(currentTime: 2.9, delta: 0.9)
        #expect(waited)
    }

    @Test("A scene presented again starts its clock again, through a transition too")
    func presentedAgain() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let first = SKScene(size: CGSize(width: 200, height: 100))
        let second = SKScene(size: CGSize(width: 200, height: 100))
        view.presentScene(first)
        _ = view.tick(currentTime: 0, delta: 0)
        var waited = false
        second.run(.sequence([.wait(forDuration: 0.2), .run { waited = true }]))
        view.presentScene(second, transition: .fade(withDuration: 0.1))
        _ = view.tick(currentTime: 0.6, delta: 0.6)
        #expect(!waited)
        _ = view.tick(currentTime: 0.85, delta: 0.25)
        #expect(waited)
    }
}

@Suite("View controllers")
struct ViewControllerTests {
    private final class Presented: UIViewController {
        var appeared: [Bool] = []

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared.append(animated)
        }
    }

    @Test("Presenting appears the presented controller at once, and either side dismisses it")
    func presentAndDismiss() {
        let root = UIViewController()
        let presented = Presented()
        var completed = 0
        root.present(presented, animated: true) { completed += 1 }
        #expect(presented.appeared == [true])
        #expect(root.presentedViewController === presented)
        #expect(presented.presentingViewController === root)
        #expect(completed == 1)

        presented.dismiss(animated: true) { completed += 1 }
        #expect(root.presentedViewController == nil)
        #expect(presented.presentingViewController == nil)
        #expect(completed == 2)

        root.present(presented, animated: false)
        root.dismiss(animated: false)
        #expect(root.presentedViewController == nil)
        #expect(presented.appeared == [true, false])
    }
}
