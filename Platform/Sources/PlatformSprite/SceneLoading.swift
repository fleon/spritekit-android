import Foundation
import SpriteKitShim

/// A scene a loading screen builds on a background thread before it shows:
/// `load()` does what showing it would otherwise start with, laid out for
/// `plannedLayout` (which `SceneLayout(scene:)` reads while the scene has no
/// view), and `didMove(to:)` loads it if nothing has.
public protocol LoadableScene: SKScene {
    var plannedLayout: SceneLayout? { get set }
    /// Builds what the scene shows, once.
    func load()
}

/// Every scene change fades through black, with the scaling every scene
/// shares; a game's loading screen comes in between through `present`.
public enum TransitionManager {
    /// The scene size for a view of `viewSize` points.
    public static var sceneSize: (_ viewSize: CGSize) -> CGSize = { $0 }
    /// How every scene is scaled into its view.
    public static var scaleMode: SKSceneScaleMode = .aspectFill
    /// How long the fade takes, out and in together.
    public static var duration: TimeInterval = 0.1

    /// Runs as each scene is about to show (a render scale changes then, so
    /// nothing changes size under a scene).
    public static var willPresent: (() -> Void)?

    /// The scenes faded out, kept until no build runs (`BuildGate`): one
    /// freed while a build attaches shaders off the main thread would take
    /// its own off the lights' shared uniforms as the build adds others.
    /// SpriteKit still updates a scene (and `SKView.scene` is still it)
    /// while the next fades in.
    private static var leavingScenes: [SKScene] = []

    /// Whether `scene` is fading out, or has.
    public static func isLeaving(_ scene: SKScene?) -> Bool {
        leavingScenes.contains { $0 === scene }
    }

    /// Shows the loading scene `loading` makes for `destination` at the
    /// view's scene size, which makes and builds the destination's scene and
    /// then shows it.
    public static func present<Destination>(
        _ destination: Destination,
        in view: SKView,
        loading: (_ size: CGSize, _ destination: Destination) -> SKScene
    ) {
        show(loading(sceneSize(view.bounds.size), destination), in: view)
    }

    /// Fades to black and back in on `scene`, sized and scaled as every scene is.
    public static func show(_ scene: SKScene, in view: SKView) {
        let leaving = view.scene
        if let leaving { leavingScenes.append(leaving) }
        willPresent?()
        scene.scaleMode = scaleMode
        let size = sceneSize(view.bounds.size)
        if scene.size != size { scene.size = size }
        let transition = SKTransition.fade(withDuration: duration)
        transition.pausesIncomingScene = false
        transition.pausesOutgoingScene = false
        view.presentScene(scene, transition: transition)
        Markers.note("scene \(String(describing: type(of: scene)))", in: scene)
        guard let leaving else { return }
        // Once SpriteKit has let it go too.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 2) {
            BuildGate.unlessBuilding("leaving \(ObjectIdentifier(leaving))") { leavingScenes.removeAll { $0 === leaving } }
        }
    }
}

/// Runs `work`, isolated to the main actor, on the calling thread instead:
/// only for building nodes nothing on screen holds yet, off the main thread
/// (as SpriteKit's own samples load scenes on a background queue): a scene
/// behind a loading screen, or a page before it joins.
public nonisolated func offMainActor<T>(_ work: @MainActor () -> T) -> T {
    BuildGate.hold {
        withoutActuallyEscaping(work) { work in
            unsafeBitCast(work, to: (() -> T).self)()
        }
    }
}

/// SpriteKit locks nothing a shader keeps of the nodes and uniforms it's
/// attached to: a shared uniform set on the main thread while a build off it
/// attaches a shader holding it throws (a collection mutated while
/// enumerated). So builds hold this gate (`offMainActor`, and what's built
/// on the main thread beside them), and updates of shared uniforms skip
/// while one does, catching up once it ends.
public nonisolated enum BuildGate {
    private static let gate = NSLock()
    private static let state = NSLock()
    nonisolated(unsafe) private static var deferred: [String: @MainActor () -> Void] = [:]

    /// Runs `work` holding the gate.
    public static func hold<T>(_ work: () -> T) -> T {
        gate.lock()
        let result = work()
        state.lock()
        gate.unlock()
        let pending = deferred
        deferred = [:]
        state.unlock()
        if !pending.isEmpty {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (key, update) in pending { unlessBuilding(key, update) }
                }
            }
        }
        return result
    }

    /// Runs `work` holding the gate on the main thread; off it, `work` is
    /// part of a build that holds it already.
    public static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? hold(work) : work()
    }

    /// Runs `update` now unless a build holds the gate, else once it ends
    /// (the latest `update` for `key`).
    @MainActor public static func unlessBuilding(_ key: String, _ update: @escaping @MainActor () -> Void) {
        state.lock()
        guard gate.try() else {
            deferred[key] = update
            state.unlock()
            return
        }
        state.unlock()
        update()
        gate.unlock()
    }
}
