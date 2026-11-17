import AndroidShell
import GameCompat
import GLESBackend
import ShellCore
import SpriteKitShim

/// Switchlings' way in: the one place the runtime and the game meet.
///
/// The shell (`Shell.start`) knows games only as a `GameHost`; this target
/// says which game, and sets up what's Switchlings' own before it launches.
/// Another game has a target like this of its own.
@_cdecl("SDL_main")
nonisolated public func SDL_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    Shell.start(argc: argc, argv: argv, game: AndroidGameController.self) {
        // Banded layers (`BandedLayerNode`): `debug.switchlings.bands`
        // `whole` draws them unbanded, a number in that many bands, for
        // measuring.
        if let bands = DebugProperty.string("debug.switchlings.bands") {
            if bands == "whole" {
                AndroidGameController.drawsBandedLayersWhole = true
            } else if let count = Int(bands), count > 0 {
                AndroidGameController.bandedLayerBands = count
            }
            Log.info("banded layers: \(bands)")
        }
    }
}

extension AndroidGameController: GameHost {}
