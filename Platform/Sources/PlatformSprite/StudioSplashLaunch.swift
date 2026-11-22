import Foundation
import SpriteKitShim

/// What holds a game's view at launch, before its first scene
/// (`StudioSplashLaunch`): what an Android controller's surface hands its
/// layouts and its appearing to.
public protocol SceneLaunch: AnyObject {
    /// `viewDidLayoutSubviews`: true while the launch holds the view, so
    /// the caller leaves its scene alone.
    func layout(_ view: SKView) -> Bool
    /// `viewDidAppear`.
    func start()
}

/// The order of a launch's steps, apart from SpriteKit so it can be checked
/// on its own: the splash presented once, on the view's first real size;
/// its clock begun once it shows and the view has appeared, in either
/// order, with whatever was ready meanwhile; what it waits for started
/// once; the hand-off made once.
public nonisolated struct StudioSplashLaunchSteps: Equatable, Sendable {
    public private(set) var isPresented = false
    public private(set) var isShown = false
    public private(set) var hasAppeared = false
    public private(set) var hasBegun = false
    public private(set) var hasHandedOff = false
    /// The conditions ready so far.
    public private(set) var answered: Set<String> = []

    public init() {}

    /// The view laid out: true when the splash should be presented now.
    public mutating func layout(hasSize: Bool) -> Bool {
        guard hasSize, !isPresented else { return false }
        isPresented = true
        return true
    }

    /// The splash is in the view. What's ready, when its clock should
    /// begin now.
    public mutating func shown() -> Set<String>? {
        isShown = true
        return begin()
    }

    /// The view appeared. Whether to start what the splash waits for (the
    /// first time only), and what's ready, when its clock should begin now.
    public mutating func appeared() -> (startWaits: Bool, begin: Set<String>?) {
        let first = !hasAppeared
        hasAppeared = true
        return (first, begin())
    }

    /// `condition` is ready: true when the splash should hear it now (it
    /// shows); else it hears it as it begins.
    public mutating func ready(_ condition: String) -> Bool {
        answered.insert(condition)
        return isShown
    }

    /// The splash is done: true the first time.
    public mutating func handOff() -> Bool {
        guard !hasHandedOff else { return false }
        hasHandedOff = true
        return true
    }

    private mutating func begin() -> Set<String>? {
        guard isShown, hasAppeared, !hasBegun else { return nil }
        hasBegun = true
        return answered
    }
}

#if canImport(UIKit) || !canImport(Darwin)

/// A game's launch, from its studio splash to its first scene: the steps
/// every view controller (and Android controller) otherwise repeats. It
/// presents the splash on the view's first real size, keeps it and its
/// footer fitted to the view, starts its clock once the view shows, runs
/// what it waits for, and hands over to the first scene with the splash's
/// crossfade.
///
///     // viewDidLoad (or the Android controller's init):
///     launch = StudioSplashScene.launch(in: skView, style: style,
///                                       waitingFor: [.gameCenter(manager)],
///                                       firstScene: .built { view in TitleScene(size: view.bounds.size) })
///     // viewDidLayoutSubviews:
///     if launch.layout(skView) { return }
///     // viewDidAppear:
///     launch.start()
///
/// Every wait is bounded by the style's `maximumDuration`: the splash never
/// holds past it, whatever has still to answer, and an answer after it
/// changes nothing.
public final class StudioSplashLaunch: SceneLaunch {
    /// Something the splash holds for, by name.
    public struct Wait {
        public let condition: String
        let run: ((@escaping () -> Void) -> Void)?

        /// Held until `wait` returns; it starts as the view appears.
        public static func until(_ condition: String, _ wait: @escaping @MainActor () async -> Void) -> Wait {
            Wait(condition: condition) { done in
                Task { @MainActor in
                    await wait()
                    done()
                }
            }
        }

        /// Held until `wait` calls `done`, on any thread; it starts as the
        /// view appears.
        public static func callback(_ condition: String, _ wait: @escaping (_ done: @escaping () -> Void) -> Void) -> Wait {
            Wait(condition: condition, run: wait)
        }

        /// Held until the game calls `StudioSplashLaunch.ready(_:)`.
        public static func reported(_ condition: String) -> Wait {
            Wait(condition: condition, run: nil)
        }
    }

    /// What follows the splash.
    public enum FirstScene {
        /// Built on the turn after the splash's clock starts, behind it,
        /// which waits for it; crossfaded into when the splash is done.
        case built((SKView) -> SKScene)
        /// Built when the splash is done (from what its waits settled), and
        /// crossfaded into.
        case whenReady((SKView) -> SKScene)
        /// The game's own hand-off (through a loading scene of its own),
        /// called when the splash is done.
        case handOff((SKView) -> Void)
    }

    public let style: StudioSplashScene.Style
    public let waits: [Wait]
    public let firstScene: FirstScene
    /// Whether the splash waits for its logo's texture before it shows, so
    /// a page decoded in software (an emulator with no ASTC) never shows
    /// without its logo. The view shows its background meanwhile.
    public let preloadsLogo: Bool
    /// Called with the first scene as the crossfade into it starts.
    public var didHandOff: ((SKScene) -> Void)?

    /// The splash, once presented.
    public private(set) var splash: StudioSplashScene?
    private weak var view: SKView?
    private var steps = StudioSplashLaunchSteps()
    private var builtScene: SKScene?

    private static let builtCondition = "studio_splash.first_scene"

    public init(style: StudioSplashScene.Style, waitingFor waits: [Wait] = [], preloadsLogo: Bool = false, firstScene: FirstScene) {
        self.style = style
        self.waits = waits
        self.preloadsLogo = preloadsLogo
        self.firstScene = firstScene
    }

    /// Whether the launch holds the view: preparing the splash or showing
    /// it. While it does, the game leaves the view's scene alone.
    public var holdsView: Bool {
        guard steps.isPresented else { return false }
        guard let splash else { return true }
        return view?.scene === splash
    }

    /// Presents the splash in `view` once it has a size (`viewDidLoad`);
    /// with none yet, the first `layout(_:)` that has one presents it.
    public func present(in view: SKView) {
        self.view = view
        guard steps.layout(hasSize: view.bounds.width > 0 && view.bounds.height > 0) else { return }
        guard preloadsLogo else { return show(in: view) }
        SKTexture.preload([txtr(style.logo)]) { [weak self, weak view] in
            DispatchQueue.main.async {
                guard let self, let view else { return }
                self.show(in: view)
            }
        }
    }

    /// `viewDidLayoutSubviews`: presents the splash if it hasn't been, and
    /// fits it and its footer to the view. True while the launch holds the
    /// view (`holdsView`), so the caller leaves its scene alone.
    @discardableResult
    public func layout(_ view: SKView) -> Bool {
        present(in: view)
        guard holdsView else { return false }
        if let splash, view.bounds.width > 0, splash.size != view.bounds.size {
            splash.size = view.bounds.size
        }
        splash?.layoutFooter()
        return true
    }

    /// `viewDidAppear`: starts the splash's clock (once it shows) and what
    /// it waits for. Only the first call starts them.
    public func start() {
        let (startWaits, begin) = steps.appeared()
        if startWaits { self.startWaits() }
        if let begin { self.begin(answered: begin) }
    }

    /// `condition` is ready: a `.reported` wait, or any the game settles
    /// itself. Before the splash shows, it's kept for it.
    public func ready(_ condition: String) {
        guard steps.ready(condition) else { return }
        splash?.ready(condition)
    }

    private func show(in view: SKView) {
        var conditions = Set(waits.map(\.condition))
        if case .built = firstScene { conditions.insert(Self.builtCondition) }
        let splash = StudioSplashScene(size: view.bounds.size, style: style, waitingFor: conditions)
        splash.scaleMode = .resizeFill
        splash.onReady = { [weak self] in self?.handOff() }
        self.splash = splash
        view.presentScene(splash)
        if let begin = steps.shown() { self.begin(answered: begin) }
    }

    private func startWaits() {
        for wait in waits {
            let condition = wait.condition
            wait.run? { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.ready(condition) }
                } else {
                    DispatchQueue.main.async { self?.ready(condition) }
                }
            }
        }
    }

    /// The view shows the splash: its clock, what was ready meanwhile, and
    /// the first scene built behind it.
    private func begin(answered: Set<String>) {
        guard let splash else { return }
        splash.startLoading()
        for condition in answered { splash.ready(condition) }
        guard case .built(let make) = firstScene else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, self.holdsView else { return }
            self.builtScene = make(view)
            self.ready(Self.builtCondition)
        }
    }

    private func handOff() {
        guard let splash, let view, view.scene === splash, steps.handOff() else { return }
        let scene: SKScene
        switch firstScene {
        case .built(let make):
            scene = builtScene ?? make(view)
            builtScene = nil
        case .whenReady(let make):
            scene = make(view)
        case .handOff(let handOff):
            handOff(view)
            return
        }
        splash.present(scene, in: view)
        didHandOff?(scene)
    }
}

extension StudioSplashScene {
    /// A launch from this splash to the game's first scene, its splash
    /// presented in `view` if the view has a size (`StudioSplashLaunch`).
    /// Keep it: call its `layout(_:)` from `viewDidLayoutSubviews` and
    /// `start()` from `viewDidAppear`.
    public static func launch(
        in view: SKView, style: Style, waitingFor waits: [StudioSplashLaunch.Wait] = [], preloadsLogo: Bool = false,
        firstScene: StudioSplashLaunch.FirstScene
    ) -> StudioSplashLaunch {
        let launch = StudioSplashLaunch(style: style, waitingFor: waits, preloadsLogo: preloadsLogo, firstScene: firstScene)
        launch.present(in: view)
        return launch
    }
}

#endif
