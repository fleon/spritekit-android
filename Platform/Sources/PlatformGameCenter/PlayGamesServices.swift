#if SPRITEKIT_SHIM
import Foundation
import PlatformShim

public extension PlayGamesMapping {
    /// The mapping a game packs into its APK, by its resource name; nil
    /// when the build carries none (Play Games wasn't set up for it).
    init?(resource: String, bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        self.init(data: data)
    }
}

public extension GameCenterManager {
    /// Puts achievements and leaderboards on Play Games. Call before
    /// `start`. Returns the achievements backend, for what else rides on
    /// its sign-in (Saved Games, the stand-in `GKLocalPlayer`).
    @discardableResult
    func usePlayGames(channel: PlatformChannel, mapping: PlayGamesMapping) -> PlayGamesAchievements {
        let games = PlayGamesAchievements(channel: channel, mapping: mapping)
        achievementService = games
        leaderboardService = PlayGamesLeaderboards(channel: channel, mapping: mapping)
        return games
    }
}
#endif
