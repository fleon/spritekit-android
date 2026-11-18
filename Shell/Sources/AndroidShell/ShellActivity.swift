import Foundation
import PlatformShim

extension Shell {
    /// Android's `Activity.finish()`: closes the game, as a game does when
    /// the player leaves it for good (Back pressed again on its title, say).
    /// `GameHost.handleBack()` answering false only sends the game to the
    /// background, as Back from any app does. Android only: Apple has no
    /// equivalent, so it's the shell's rather than the shim's.
    public static func finishActivity() {
        PlatformChannel.shared?.call("device.finish")
    }
}
