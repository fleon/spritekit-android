#if SPRITEKIT_SHIM
import Foundation

/// Runs main-actor code on whatever thread calls, unchecked.
///
/// SpriteKit's nodes are main-actor isolated (they descend from
/// `UIResponder`), but Objective-C never enforces it, and the game relies on
/// that: a share film's stage is built, updated and drawn on the film's own
/// thread through `SKRenderer`, taking turns with the screen
/// (`FilmDrawTurns`), and the loading screen builds a scene off the main
/// thread (`offMainActor`). Here the isolation is checked by Swift, so the
/// shim's own off-main entry points say what Objective-C would have let
/// pass, and nothing more.
@inline(__always)
func mainActorUnchecked<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    try withoutActuallyEscaping(body) { body in
        try unsafeBitCast(body, to: (() throws -> T).self)()
    }
}
#endif
