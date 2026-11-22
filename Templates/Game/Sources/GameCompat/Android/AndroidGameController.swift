import PlatformAndroid
import PlatformAndroidHost
import PlatformDisplay
import PlatformGameCenter
import PlatformSprite
import SpriteKit
import UIKit

/// What stands where the game's `GameViewController` and `AppDelegate`
/// stand on Apple: the game's one `SKView` (on `surface`), the launch work
/// in the app delegate's order, and the studio splash (`StudioSplashLaunch`)
/// into the first scene. Everything else `GameHost` asks is
/// `AndroidGameHost`'s, until the game writes its own (Back, keys, links).
public final class AndroidGameController: AndroidGameHost {
    public let surface: GameHostSurface

    /// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, in its
    /// order, with Google Play's services in place of Apple's. `link` is the
    /// link the app was opened with, if any.
    public static func launch(link: URL?) {
        // The game's own managers: its `GameCenterManager`, and its
        // `StoreManager` if it sells anything.
        let services = AndroidPlatformServices.Configuration.toolkit(gameCenter: GAME_GAME_CENTER)
        AndroidPlatformServices.install(services)
        DisplaySettings.configuration = .withLaunchSplash
    }

    /// The scene's size for a view of `size` points, as `GameViewController`
    /// sizes it.
    public static func sceneSize(for size: CGSize) -> CGSize {
        size
    }

    public init(view: SKView) {
        surface = GameHostSurface(view: view)
        // `LaunchSplash.style` is the game's: its logo, footer and font.
        surface.launch = StudioSplashLaunch(style: LaunchSplash.style, firstScene: .built { view in
            let scene = TitleScene(size: Self.sceneSize(for: view.bounds.size))
            scene.scaleMode = .aspectFill
            return scene
        })
    }
}
