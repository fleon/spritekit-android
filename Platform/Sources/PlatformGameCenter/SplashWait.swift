import Foundation
import PlatformSprite
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import UIKit
#endif

#if canImport(UIKit) || !canImport(Darwin)
extension StudioSplashLaunch.Wait {
    /// Signs the player in to `manager` once the view shows (`start`), and
    /// holds the splash until the service first answers: signed in,
    /// offering its sheet, or failed. Never past the splash's maximum.
    public static func gameCenter(
        _ manager: GameCenterManager, presentSignIn: ((UIViewController) -> Void)? = nil, condition: String = "gameCenter"
    ) -> Self {
        .callback(condition) { done in manager.start(presentSignIn: presentSignIn, answered: done) }
    }
}
#endif
