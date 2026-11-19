import Foundation

/// The service a game's achievements and leaderboards go to on this
/// platform: Game Center on Apple platforms, Google Play Games on Android.
/// A game names its Game Center button (and anything else that names the
/// service) after it, so the player sees the name of the service that
/// opens, with no platform check in the game.
public enum GameService: String, Sendable, CaseIterable {
    case gameCenter
    case playGames

    /// The service `GameCenterManager` speaks to where this is built.
    public nonisolated static var current: GameService {
        #if SPRITEKIT_SHIM
        .playGames
        #else
        .gameCenter
        #endif
    }
}

extension GameCenterManager {
    /// The service behind this manager on this platform (`GameService.current`).
    public nonisolated var service: GameService { .current }
}
