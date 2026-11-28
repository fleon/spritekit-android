#if SPRITEKIT_SHIM
import Foundation
import PlatformAndroid
import PlatformDisplay
import PlatformGameCenter
import PlatformShim
import PlatformSprite
import PlatformStore
import SpriteKitShim
import Testing
@testable import PlatformAndroidHost

/// A controller that writes only what `AndroidGameHost` leaves it.
private final class Controller: AndroidGameHost {
    let surface: GameHostSurface
    var laidOut: [CGSize] = []

    init(view: SKView) {
        surface = GameHostSurface(view: view)
    }

    static func sceneSize(for size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 800)
    }

    func didLayout(_ scene: SKScene) {
        laidOut.append(scene.size)
    }
}

/// A launch that holds the view while told to.
private final class FakeLaunch: SceneLaunch {
    var holds = true
    var layouts = 0
    var starts = 0

    func layout(_ view: SKView) -> Bool {
        layouts += 1
        return holds
    }

    func start() {
        starts += 1
    }
}

@MainActor
@Suite(.serialized)
struct GameHostSurfaceTests {
    private let insets = UIEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)

    @Test("The view sits in a window whose scene is kept")
    func windowScene() {
        let view = SKView(bounds: .zero)
        let surface = GameHostSurface(view: view)
        #expect(view.window === surface.window)
        #expect(surface.window.windowScene === surface.windowScene)
        #expect(surface.windowScene.screen === surface.screen)
        #expect(view.ignoresSiblingOrder)
    }

    @Test("A layout reaches the view, the window, the screen, the idiom and the frame rates")
    func apply() {
        let view = SKView(bounds: .zero)
        view.contentScaleFactor = 3
        let surface = GameHostSurface(view: view)
        surface.apply(size: CGSize(width: 400, height: 900), safeArea: insets, orientation: .landscapeLeft, idiom: .pad, maximumFramesPerSecond: 120)
        #expect(view.bounds.size == CGSize(width: 400, height: 900))
        #expect(view.safeAreaInsets == insets)
        #expect(surface.window.bounds == view.bounds)
        #expect(surface.window.safeAreaInsets == insets)
        #expect(surface.screen.bounds == view.bounds)
        #expect(surface.screen.nativeBounds.size == CGSize(width: 1200, height: 2700))
        #expect(surface.windowScene.effectiveGeometry.interfaceOrientation == .landscapeLeft)
        #expect(UITraitCollection.idiom == .pad)
        #expect(DisplaySettings.screenMaximum == 120)
        surface.apply(size: CGSize(width: 400, height: 900), safeArea: insets, orientation: .portrait, idiom: .phone, maximumFramesPerSecond: 60)
        #expect(UITraitCollection.idiom == .phone)
        #expect(DisplaySettings.screenMaximum == 60)
    }

    @Test("-SafeAreaInsets stands in for the device's safe area")
    func safeAreaOverride() throws {
        let defaults = try #require(UserDefaults(suiteName: "GameHostSurfaceTests.safeArea"))
        defer { defaults.removePersistentDomain(forName: "GameHostSurfaceTests.safeArea") }
        #expect(GameHostSurface.safeArea(insets, defaults: defaults) == insets)
        defaults.set("59,0,34,0", forKey: SafeAreaOverride.argument)
        #expect(GameHostSurface.safeArea(insets, defaults: defaults) == UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        defaults.set("nonsense", forKey: SafeAreaOverride.argument)
        #expect(GameHostSurface.safeArea(insets, defaults: defaults) == insets)
    }

    @Test("A launch number reads as a number, text or a fraction, and only when positive")
    func launchNumber() throws {
        let defaults = try #require(UserDefaults(suiteName: "GameHostSurfaceTests.numbers"))
        defer { defaults.removePersistentDomain(forName: "GameHostSurfaceTests.numbers") }
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == nil)
        defaults.set(0.0333, forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == 0.0333)
        defaults.set("0.85", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == 0.85)
        defaults.set("-1", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == nil)
        defaults.set("zero", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == nil)
        defaults.set("1/60", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == 1.0 / 60)
        defaults.set(" 1 / 30 ", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == 1.0 / 30)
        defaults.set("1/0", forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == nil)
        defaults.set(-0.5, forKey: "Step")
        #expect(GameHostSurface.launchNumber("Step", defaults: defaults) == nil)
    }

    @Test("The default fixed frame step takes a plain number or a fraction")
    func fixedFrameStep() {
        let key = "FixedFrameStep"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.removeObject(forKey: key)
        #expect(Controller.fixedFrameStep == nil)
        defaults.set("0.0333", forKey: key)
        #expect(Controller.fixedFrameStep == 0.0333)
        defaults.set("1/60", forKey: key)
        #expect(Controller.fixedFrameStep == 1.0 / 60)
        defaults.set("0/60", forKey: key)
        #expect(Controller.fixedFrameStep == nil)
    }

    @Test("The launch holds the view until it lets go; then the scene follows the view")
    func layoutWithLaunch() {
        let view = SKView(bounds: .zero)
        let controller = Controller(view: view)
        let launch = FakeLaunch()
        controller.surface.launch = launch
        controller.layout(size: .zero, safeArea: .zero, orientation: .portrait, idiom: .phone, maximumFramesPerSecond: 60)
        #expect(launch.layouts == 0)
        view.presentScene(SKScene(size: CGSize(width: 1, height: 1)))
        controller.layout(size: CGSize(width: 390, height: 844), safeArea: insets, orientation: .portrait, idiom: .phone, maximumFramesPerSecond: 60)
        #expect(launch.layouts == 1)
        #expect(view.scene?.size == CGSize(width: 1, height: 1))
        #expect(controller.laidOut.isEmpty)
        controller.didAppear()
        #expect(controller.surface.hasAppeared)
        #expect(launch.starts == 1)
        launch.holds = false
        controller.layout(size: CGSize(width: 390, height: 844), safeArea: insets, orientation: .portrait, idiom: .phone, maximumFramesPerSecond: 60)
        #expect(view.scene?.size == CGSize(width: 390, height: 800))
        #expect(controller.laidOut == [CGSize(width: 390, height: 800)])
    }

    @Test("The defaults: Back, links and the frame clock left alone, the capture hook on the surface")
    func defaults() {
        let controller = Controller(view: SKView(bounds: .zero))
        #expect(!controller.handleBack())
        #expect(!Controller.holdsFrameClock)
        controller.captureFrame = { _ in }
        #expect(controller.surface.captureFrame != nil)
        #expect(controller.debugSummary.contains("scene none"))
    }
}

@MainActor
@Suite(.serialized)
struct ToolkitServicesTests {
    private func gameCenter() -> GameCenterManager {
        GameCenterManager(configuration: .init(progress: { _ in [:] }, logSubsystem: "test", defaults: UserDefaults(suiteName: "ToolkitServicesTests")!))
    }

    @Test("Each manager given receives its backend; those left out, none")
    func receivers() {
        let services = AndroidPlatformServices.Configuration.toolkit(gameCenter: gameCenter())
        #expect(services.achievements != nil)
        #expect(services.leaderboards != nil)
        #expect(services.cloud != nil)
        #expect(services.billing == nil)
        let bare = AndroidPlatformServices.Configuration.toolkit(gameCenter: nil, syncsSavedData: false)
        #expect(bare.achievements == nil)
        #expect(bare.leaderboards == nil)
        #expect(bare.cloud == nil)
    }

    @Test("Play Billing takes the store's products, its consumables and the server's")
    func billing() throws {
        let defaults = try #require(UserDefaults(suiteName: "ToolkitServicesTests.store"))
        defer { defaults.removePersistentDomain(forName: "ToolkitServicesTests.store") }
        let store = StoreManager(configuration: .init(
            products: [
                .nonConsumable("unlock"),
                StoreProduct("hints", kind: .consumable),
                StoreProduct("coins", kind: .consumable, consumedBy: .server),
            ],
            defaults: defaults
        ), billing: NoBilling())
        let billing = AndroidPlatformServices.Billing(store: store)
        #expect(billing.products == ["unlock", "hints", "coins"])
        #expect(billing.consumables == ["hints", "coins"])
        #expect(billing.serverConsumed == ["coins"])
        #expect(!billing.simulated)
        let services = AndroidPlatformServices.Configuration.toolkit(gameCenter: nil, store: store)
        #expect(services.billing?.products == billing.products)
    }
}
#endif
