import PlatformShim
import SpriteKit
import UIKit

/// What stands where `Source/GameViewController.swift` stands on Apple: it
/// holds the game's one `SKView`, lays it out, presents the launch splash and
/// then the first screen through `TransitionManager`, resumes the screen the
/// game was left on (`ResumeScreen`), and routes input to the scene the way
/// the Apple controller does — touches through the window (`TouchOriginWindow`
/// notes each one), the Android back button as the remote's Back (Escape, and
/// out of the game only from the title or the splash), a hardware keyboard to
/// `KeyboardControllable`, and gamepads through `GamepadInput` into
/// `FocusNavigator`.
///
/// The decisions are the Apple file's, copied where they are pure game logic
/// (`initialDestination`, `resumedDestination`, `handleGamepad`, the splash's
/// hand-off) and kept in step with it. What the Apple file does through
/// UIKit — `loadView`, gesture recognisers, presses, the status bar,
/// supported orientations — the shell does through SDL, calling in here.
///
/// Left out, as Apple-only: the Mac's window and hover focus, Apple TV's
/// remote echoes, Game Center's sign-in sheet (Android has no Game Center)
/// and the iOS edge swipe (Android's back gesture arrives as the back
/// button). The debug scripts and captures (`-TouchScript`, `-Stills`,
/// `-SnapshotLevels`…) are in `AndroidGameController+Scripts.swift`.
public final class AndroidGameController {
    public let view: SKView
    private let window: TouchOriginWindow
    private let screen: UIScreen
    private var splash: LaunchSplashScene? { view.scene as? LaunchSplashScene }
    private var hasAppeared = false
    private var hasGameCenterAnswered = false
    var focus: FocusNavigator?
    private let gamepads = GamepadInput()
    /// `-FrameLog`'s log, which the view holds only weakly.
    var frameLog: FrameLog?
    /// Hands `done` the next frame the view draws, as pixels (`-SnapshotEvery`,
    /// `-SnapshotLevels`); the renderer sets it. `drawHierarchy`'s part.
    public var captureFrame: ((@escaping (RasterImage?) -> Void) -> Void)?

    /// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`: what
    /// the game starts before its first scene, in the same order. `link` is
    /// the link the game was opened with, if any (SceneDelegate's
    /// `connectionOptions.urlContexts`).
    public static func launch(link: URL?) {
        AndroidPlatformServices.install()
        ICloudSyncManager.shared.start(syncing: [
            Progress.syncedKeys,
            Localization.syncedKeys,
            AudioManager.syncedKeys,
            HapticsManager.syncedKeys,
            GameCenterManager.syncedKeys,
        ])
        if LaunchArguments.shouldResetProgress {
            Progress.reset()
        }
        AudioManager.loadSettings()
        HapticsManager.loadSettings()
        StoreManager.shared.start()
        DesignerFeed.shared.start()
        PlaytestLog.shared.flush()
        // As `SceneDelegate.sceneDidBecomeActive`: the beta's level feed and
        // solve log catch up whenever the game comes back to the front.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                DesignerFeed.shared.refresh()
                PlaytestLog.shared.flush()
            }
        }
        // As `SceneDelegate` connects its scene: the link the game opened
        // with, else `-OpenLink`, else `-OpenCode`; `-OpenLinkAfter` holds
        // `-OpenLink` back until the game is running (`didAppear`).
        let links = LaunchLinks.plan(
            link: link?.absoluteString,
            openLink: LaunchArguments.openLink?.absoluteString,
            openLinkAfter: LaunchArguments.openLinkAfter,
            openCode: LaunchArguments.openCode
        )
        let opening = links.atLaunch.flatMap(URL.init(string:))
        if let url = opening, WorldLink.isWorldLink(url) {
            WorldLink.pending = .some(WorldLink.world(opening: url))
        } else if let url = opening, let code = LevelShare.code(opening: url) {
            LevelShare.pendingCode = code
        } else if let text = links.code, let code = LevelShare.code(in: text) {
            LevelShare.pendingCode = code
        }
        laterLink = links.later.flatMap(URL.init(string:)).map { ($0, links.delay ?? 0) }
    }

    /// `-FixedFrameStep`'s step (`LaunchArguments.fixedFrameStep`), which the
    /// shell's clock takes.
    public static var fixedFrameStep: TimeInterval? { LaunchArguments.fixedFrameStep }

    /// Whether frames wait on work off the main thread (`MediaClock.isHeld`).
    public static var holdsFrameClock: Bool { MediaClock.isHeld }

    /// The shell's audio, once SDL has opened a device: until this the game's
    /// `AudioManager` stands on its silent backend, so its sounds load again
    /// into this one and any track already asked for starts.
    public static func useAudio(_ backend: AudioBackend) {
        AudioManager.use(backend)
    }

    /// The frame rates and render scales the renderer may draw at, fastest
    /// and largest first (one, where the player picked or something pins
    /// it), and whether Auto moves between them at all
    /// (`DisplaySettings.choices`).
    public static var displayChoices: (rates: [Int], scales: [Double], governs: Bool) {
        DisplaySettings.choices
    }

    /// A render scale nothing moves (`-RenderScale`, or a capture running).
    public static var pinnedRenderScale: Double? { DisplaySettings.pinnedRenderScale }

    /// Where Auto starts: the load (pixels a second, in screens) this device
    /// settled at last time.
    public static var startingLoad: Double? { DisplaySettings.startingLoad }

    /// Rungs at least this costly aren't tried this launch: one ran late
    /// on this device lately.
    public static var startingBlock: Double? { DisplaySettings.startingBlock }

    /// A rung this costly ran late: kept for a few launches.
    public static func noteBlocked(load: Double) {
        DisplaySettings.noteBlocked(load)
    }

    /// Calls `changed` whenever the player picks a frame rate or quality (or
    /// Auto), Low Power Mode comes or goes, or the screen's fastest rate
    /// changes: the renderer applies `displayChoices` at once.
    public static func observeDisplayChoices(_ changed: @escaping @MainActor () -> Void) {
        for name in [DisplaySettings.choicesDidChange, Notification.Name.NSProcessInfoPowerStateDidChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
            }
        }
    }

    /// Whether frames of `scene` measure how the game draws: not the
    /// loading screen's or the splash's.
    public static func isMeasured(_ scene: SKScene?) -> Bool {
        TransitionManager.isMeasured(scene)
    }

    /// Whether the backdrops' costliest shaders draw whole, one sprite
    /// redrawn every frame, instead of in `BandedLayerNode`'s cached bands.
    /// Set before the first backdrop builds.
    public static var drawsBandedLayersWhole: Bool {
        get { BandedLayerNode.drawsWhole }
        set { BandedLayerNode.drawsWhole = newValue }
    }

    /// The bands each of them draws in otherwise (8). Set before the first
    /// backdrop builds.
    public static var bandedLayerBands: Int {
        get { BandedLayerNode.bandCount }
        set { BandedLayerNode.bandCount = max(newValue, 1) }
    }

    /// Where Auto stood as it judged a window of frames: a running average
    /// of these is where the next launch starts.
    public static func noteAuto(rate: Int, scale: Double) {
        DisplaySettings.noteAuto(.init(rate: rate, scale: scale))
    }

    /// What the renderer draws at now, which the settings show as Auto's.
    public static func setRunning(rate: Int, scale: Double) {
        DisplaySettings.running = .init(rate: rate, scale: scale)
    }

    /// `-OpenLinkAfter`'s link and delay, opened once the game shows.
    private static var laterLink: (url: URL, delay: TimeInterval)?

    /// For the shell's scene dump: the view's safe area and the last level
    /// layout `GameScene` reported (debug builds).
    public var debugSummary: String {
        var text = "view \(view.bounds.size) safe \(view.safeAreaInsets)"
        if let scene = view.scene { text += " layout visible \(SceneLayout(scene: scene).visibleRect) safe \(SceneLayout(scene: scene).safeRect)" }
        #if DEBUG
        text += " level \(GameScene.layoutReport)"
        #endif
        return text
    }

    /// `DesignSystem.sceneSize(for:)`: the scene for a view of `size` points.
    public static func sceneSize(for size: CGSize) -> CGSize {
        DesignSystem.sceneSize(for: size)
    }

    public init(view: SKView) {
        self.view = view
        screen = UIScreen(bounds: view.bounds, nativeScale: view.contentScaleFactor)
        window = TouchOriginWindow(bounds: view.bounds)
        window.windowScene = UIWindowScene(screen: screen, interfaceOrientation: .portrait)
        view.window = window
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = true
        view.backgroundColor = Theme.launchSplashBackground
        gamepads.onAction = { [weak self] in self?.handleGamepad($0) }
        gamepads.onDisconnectAll = { [weak self] in self?.releaseFocus() }
        // A touch takes focus back from a gamepad, as the Apple controller's
        // `TouchWatcher` does.
        window.observer = { [weak self] event in
            if event.allTouches?.contains(where: { $0.phase == .began }) == true { self?.releaseFocus() }
        }
        NotificationCenter.default.addObserver(forName: ICloudSyncManager.didUpdateLocalData, object: nil, queue: nil) { [weak self] notification in
            let keys = Set(notification.userInfo?[ICloudSyncManager.updatedKeysUserInfoKey] as? [String] ?? [])
            MainActor.assumeIsolated { self?.savedDataDidSync(keys) }
        }
        startScripts()
        MainframeReward.watch(view)
    }

    // MARK: - Layout

    /// The view's size in points, what system bars and cutouts cover, which
    /// way the device stands, its idiom and the screen's fastest refresh:
    /// `viewDidLayoutSubviews`, as the shell learns them from SDL. The first
    /// call presents the splash.
    public func layout(size: CGSize, safeArea: UIEdgeInsets, orientation: UIInterfaceOrientation, idiom: UIUserInterfaceIdiom, maximumFramesPerSecond: Int) {
        var safeArea = safeArea
        #if DEBUG
        // `-SafeAreaInsets top,left,bottom,right`: a parity run's iPhone
        // safe area in place of the device's.
        if let forced = SafeAreaOverride.parse(UserDefaults.standard.string(forKey: SafeAreaOverride.argument)) {
            safeArea = UIEdgeInsets(top: forced.top, left: forced.left, bottom: forced.bottom, right: forced.right)
        }
        #endif
        let bounds = CGRect(origin: .zero, size: size)
        view.bounds = bounds
        view.safeAreaInsets = safeArea
        window.bounds = bounds
        window.safeAreaInsets = safeArea
        screen.bounds = bounds
        screen.nativeScale = view.contentScaleFactor
        screen.nativeBounds = CGRect(x: 0, y: 0, width: size.width * view.contentScaleFactor, height: size.height * view.contentScaleFactor)
        window.windowScene?.effectiveGeometry.interfaceOrientation = orientation
        UIDevice.current.userInterfaceIdiom = idiom
        // The frame rates on offer follow it (`observeDisplayChoices`).
        if maximumFramesPerSecond != DisplaySettings.screenMaximum {
            DisplaySettings.screenMaximum = maximumFramesPerSecond
        }
        guard let scene = view.scene else {
            if size.width > 0 { presentSplash() }
            return
        }
        if let splash = scene as? LaunchSplashScene {
            splash.size = size
            splash.layoutFooter()
            return
        }
        let sceneSize = DesignSystem.sceneSize(for: size)
        if scene.size != sceneSize { scene.size = sceneSize }
    }

    /// `viewDidAppear`: the splash starts loading and Game Center (Play Games
    /// on Android, a seam for now) is asked to sign in.
    public func didAppear() {
        startCaptures()
        if let later = Self.laterLink {
            Self.laterLink = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + later.delay) { [weak self] in self?.open(later.url) }
        }
        hasAppeared = true
        splash?.startLoading()
        GameCenterManager.shared.start(presentSignIn: { _ in }) { [weak self] in
            self?.hasGameCenterAnswered = true
            self?.splash?.gameCenterAnswered()
        }
    }

    private func presentSplash() {
        let splash = LaunchSplashScene(size: view.bounds.size)
        splash.scaleMode = .resizeFill
        splash.onReady = { [weak self] in self?.presentInitialScene() }
        view.presentScene(splash)
        if hasAppeared { splash.startLoading() }
        if hasGameCenterAnswered { splash.gameCenterAnswered() }
    }

    /// The splash fades through black into the loading screen, which builds the first scene.
    private func presentInitialScene() {
        guard view.scene is LaunchSplashScene else { return }
        view.backgroundColor = WorldTheme.garden.palette.backgroundTop
        TransitionManager.present(initialDestination, in: view)
    }

    private func savedDataDidSync(_ keys: Set<String>) {
        Localization.savedDataDidSync(keys)
        AudioManager.savedDataDidSync(keys)
        GameCenterManager.shared.savedDataDidSync(keys)
        (view.scene as? SavedDataObserving)?.savedDataDidSync(keys)
    }

    // MARK: - Input

    /// Android's back button (and back gesture): the remote's Back on Apple
    /// TV, so Escape — it closes a popup or goes back. False means nothing
    /// took it on the title or the splash, so the game should leave, as
    /// Apple TV's Menu leaves from the title.
    public func handleBack() -> Bool {
        // The pre-registration reward's notice is the shim's, not the scene's.
        if MainframeReward.dismiss() { return true }
        let scene = view.scene
        let handled = (scene as? KeyboardControllable)?.handleKey(.keyboardEscape, modifiers: []) ?? false
        return handled || !(scene is TitleScene || scene is LaunchSplashScene)
    }

    /// A hardware keyboard's key, as `pressesBegan` hands it on.
    @discardableResult
    public func handleKey(_ key: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        (view.scene as? KeyboardControllable)?.handleKey(key, modifiers: modifiers) ?? false
    }

    /// A link opened the game (`switchlings://…`): a friend's level or a world.
    public func open(_ url: URL) {
        if WorldLink.isWorldLink(url) {
            openWorld(WorldLink.world(opening: url))
            return
        }
        guard let code = LevelShare.code(opening: url) else { return }
        if let scene = view.scene as? SharedLevelOpening {
            scene.openSharedLevel(code)
        } else {
            LevelShare.pendingCode = code
        }
    }

    private func openWorld(_ index: Int?) {
        guard let scene = view.scene, !(scene is LaunchSplashScene) else {
            WorldLink.pending = .some(index)
            return
        }
        guard !(scene is LoadingScene) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignSystem.worldLinkRetry) { [weak self] in self?.openWorld(index) }
            return
        }
        TransitionManager.present(WorldLink.destination(index), in: view)
    }

    /// What a gamepad's buttons do: as `GameViewController.handleGamepad`.
    private func handleGamepad(_ action: GamepadInput.Action) {
        let scene = view.scene
        let keys = scene as? KeyboardControllable
        switch action {
        case .move(let direction):
            _ = takeFocus()?.move(direction)
        case .select:
            _ = takeFocus()?.select()
        case .back:
            if !handleBack() { leave?() }
        case .undo:
            _ = keys?.handleKey(.keyboardU, modifiers: [])
        case .restart:
            _ = keys?.handleKey(.keyboardR, modifiers: [])
        case .hint:
            _ = keys?.handleKey(.keyboardH, modifiers: [])
        case .menu:
            (scene as? MenuToggling)?.toggleMenu()
        }
    }

    /// What the shell does when back leaves the game.
    public var leave: (() -> Void)?

    /// Focus for a gamepad: the first press after touch only brings it up.
    private func takeFocus() -> FocusNavigator? {
        if let focus { return focus }
        focus = FocusNavigator(view: view)
        _ = focus?.refresh()
        return nil
    }

    /// A touch takes over from a gamepad: focus no longer shows.
    private func releaseFocus() {
        guard let focus else { return }
        focus.stop()
        self.focus = nil
    }

    // MARK: - The first screen

    private var initialDestination: Destination {
        if let id = LaunchArguments.startLevelID, let entry = LevelCatalog.level(withID: id) {
            return .level(entry)
        } else if let index = LaunchArguments.startWorldIndex, LevelCatalog.world(at: index) != nil {
            return .worlds(index: index)
        } else if LaunchArguments.startsAtWorlds {
            return .worlds()
        } else if LaunchArguments.startsAtCollection {
            return .collection(theme: LaunchArguments.titleWorld ?? .garden)
        } else if LaunchArguments.startsAtTitle {
            return .title
        } else if LaunchArguments.startsAtDesigner {
            return .designer(showing: .mine)
        } else if LaunchArguments.startsAtEditor {
            let theme = LaunchArguments.titleWorld ?? .garden
            if let level = LaunchArguments.editorLevel { return .designerEditor(DesignerStore.shared.newDraft(theme: theme, level: level).id) }
            return .designerEditor((DesignerStore.shared.drafts.first ?? DesignerStore.shared.newDraft(theme: theme)).id)
        }
        if let link = WorldLink.pending {
            WorldLink.pending = nil
            return WorldLink.destination(link)
        }
        guard LevelShare.pendingCode == nil else { return .title }
        return resumedDestination ?? .title
    }

    /// The screen the game was left on, while it's still open: as
    /// `GameViewController.resumedDestination`.
    private var resumedDestination: Destination? {
        switch ResumeScreen.saved {
        case .level(let id)?:
            guard let entry = LevelCatalog.level(withID: id), let world = LevelCatalog.world(at: entry.worldIndex) else { return nil }
            guard StoreManager.shared.shows(world) else { return .worlds() }
            guard StoreManager.shared.isUnlocked(world), Progress.isUnlocked(entry, in: world) else { return .worlds(index: entry.worldIndex) }
            return .level(entry)
        case .worlds(let index, let level)?:
            guard let world = LevelCatalog.world(at: index) else { return nil }
            guard StoreManager.shared.shows(world) else { return .worlds() }
            let open = world.levels.first { $0.number == level }.map { Progress.isUnlocked($0, in: world) } ?? false
            return .worlds(index: index, focus: open ? level : nil)
        case .collection(let tab, let theme)?:
            return .collection(theme: WorldTheme(rawValue: theme) ?? .garden, tab: tab)
        case .designer(let tab)?:
            guard StoreManager.shared.isFullGameUnlocked else { return nil }
            return .designer(showing: DesignerLevelsSheetNode.Tab(rawValue: tab) ?? .mine)
        case .editor(let id)?:
            guard StoreManager.shared.isFullGameUnlocked else { return nil }
            return .designerEditor(id)
        case .designerLevel(let id)?:
            guard StoreManager.shared.isFullGameUnlocked else { return nil }
            guard let draft = DesignerStore.shared.draft(id) else { return .designer(showing: .mine) }
            guard draft.board.problem == nil else { return .designerEditor(id) }
            return .designerPlay(DesignerPlay(level: draft.level, theme: draft.theme, source: .draft(id)))
        case .friendLevel(let code)?:
            guard StoreManager.shared.isFullGameUnlocked else { return nil }
            guard let friend = DesignerStore.shared.friendLevel(code) else { return .designer(showing: .friends) }
            return .designerPlay(DesignerPlay(level: friend.level, theme: friend.theme, source: .friend(code: code)))
        case nil:
            return nil
        }
    }
}
