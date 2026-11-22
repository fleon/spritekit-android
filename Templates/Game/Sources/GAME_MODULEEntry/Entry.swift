import AndroidShell
import Foundation
import GameCompat
import GLESBackend
import PlatformAndroidHost
import ShellCore
import SpriteKitShim

/// GAME_NAME's way in: the one place the runtime and the game meet.
///
/// The shell (`Shell.start`) knows games only as a `GameHost`; this target
/// says which game.
@_cdecl("SDL_main")
nonisolated public func SDL_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    Shell.start(
        argc: argc, argv: argv,
        app: AppIdentity(name: "GAME_NAME", bundleIdentifier: "PACKAGE_NAME", key: "GAME_KEY"),
        // `UIAppFonts` in the Info.plist, staged in the APK's fonts/: the
        // game's faces and the launch splash's.
        fonts: [GAME_FONTS],
        game: AndroidGameController.self
    )
}

/// Every member the controller doesn't write is `AndroidGameHost`'s (the
/// surface, audio, the frame clock) and `DisplaySettingsHost`'s (Auto).
extension AndroidGameController: GameHost {}
