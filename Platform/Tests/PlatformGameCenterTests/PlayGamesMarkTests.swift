import Foundation
import PlatformSprite
import Testing
@testable import PlatformGameCenter

@Suite("Play Games mark")
@MainActor
struct PlayGamesMarkTests {
    @Test("Its parts are filled shapes on the 24-unit grid, the gamepad inside the triangle")
    func parts() {
        let bounds = PlayGamesMark.parts.map { SVGPath.path($0.path).boundingBoxOfPath }
        #expect(bounds.count == 3)
        #expect(bounds.allSatisfy { !$0.isEmpty && $0.minX > -1 && $0.maxX < 26 && $0.minY > -1 && $0.maxY < 27 })
        #expect(bounds[0].contains(bounds[1]) && bounds[0].contains(bounds[2]))
        #expect(bounds[0].contains(PlayGamesMark.centre))
        // Its two greens, the gamepad light on the dark triangle.
        #expect(PlayGamesMark.parts.map(\.green) == [128, 254, 128])
    }

    @Test("Where Play Games can't run its button hides, and Game Center's never does")
    func hidesButton() {
        let manager = GameCenterManager(
            configuration: .init(progress: { _ in [:] }, logSubsystem: "test", defaults: UserDefaults(suiteName: UUID().uuidString)!),
            achievements: LocalAchievements(),
            leaderboards: LocalLeaderboards()
        )
        #if SPRITEKIT_SHIM
        #expect(PlayGamesMark.hidesButton(for: manager))
        #else
        #expect(!PlayGamesMark.hidesButton(for: manager))
        #endif
    }

    @Test("The service is Play Games on the shim, Game Center on Apple platforms")
    func service() {
        let manager = GameCenterManager(
            configuration: .init(progress: { _ in [:] }, logSubsystem: "test", defaults: UserDefaults(suiteName: UUID().uuidString)!),
            achievements: LocalAchievements(),
            leaderboards: LocalLeaderboards()
        )
        #if SPRITEKIT_SHIM
        #expect(GameService.current == .playGames)
        #else
        #expect(GameService.current == .gameCenter)
        #endif
        #expect(manager.service == GameService.current)
    }
}
