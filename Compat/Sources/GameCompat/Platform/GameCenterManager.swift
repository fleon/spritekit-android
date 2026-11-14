import Foundation
import PlatformShim
import UIKit

/// `Source/Utils/GameCenterManager.swift` on Android: the same API for the
/// same callers, with Play Games Services v2 where GameKit was.
///
/// The bookkeeping is the Apple file's: board firsts are kept in the game's
/// own saved data as a synced set, what the service holds is loaded,
/// compared, and only the achievements that have moved are sent. Behind it,
/// `PlayGamesAchievements` (installed by `AndroidPlatformServices` when the
/// build carries Play Games' IDs) maps each achievement to Play's, as an
/// unlock or as steps, or `LocalAchievements` keeps the percentages on the
/// device when it doesn't.
///
/// Sign-in is Play Games v2's own, silent: there is no sheet to present, and
/// play never waits on it. The signed-in player's Play Games name and
/// picture credit a Level Designer level they share, as Game Center's do.
///
/// The title's Game Center button is Play Games' here (its controller,
/// `GameCenterIcon`): it opens Play Games' achievements, signing a
/// signed-out player in first, and stands only where Play Games can run.
final class GameCenterManager {
    static let shared = GameCenterManager()

    private enum Key {
        static let moments = "gameCenter.moments"
    }

    /// What the player's devices keep the same.
    static let syncedKeys: [String: ICloudSyncManager.Merge] = [Key.moments: .union]

    /// Where achievements go (see above).
    static var service: AchievementsBackend = LocalAchievements()

    /// Board firsts the player has had, kept for a later sign-in to report.
    private var moments: Set<Achievement.Moment>
    /// What the service holds for each achievement, as last loaded or sent.
    private var reported: [String: Double] = [:]
    private var hasStarted = false
    private var hasAnswered = false
    private var answerHandlers: [() -> Void] = []

    private init() {
        moments = Self.savedMoments()
    }

    private static func savedMoments() -> Set<Achievement.Moment> {
        Set((UserDefaults.standard.stringArray(forKey: Key.moments) ?? []).compactMap(Achievement.Moment.init(rawValue:)))
    }

    /// Signs the player in. `answered` runs once the service first answers;
    /// with no service that is at once, which is what the launch splash
    /// needs — it holds for this before building the first scene.
    ///
    /// `presentSignIn` is kept in the signature because `AppDelegate` passes
    /// it. Nothing calls it: Play Games signs in without a sheet.
    func start(presentSignIn: @escaping (UIViewController) -> Void, answered: (() -> Void)? = nil) {
        if let answered {
            if hasAnswered { answered() } else { answerHandlers.append(answered) }
        }
        guard !hasStarted else { return }
        hasStarted = true
        Self.service.start { [weak self] in
            Task { @MainActor in self?.answeredFirst() }
        }
    }

    /// What the title asks before its button opens the dashboard rather
    /// than Game Center's "sign in from Settings" notice (`TitleScene`, the
    /// game's only caller). Play Games' dashboard signs the player in itself
    /// (`showDashboard`), so wherever it can open this is true, signed in or
    /// not; without Play Games the button isn't shown at all.
    var isSignedIn: Bool { Self.service.opensDashboard }

    /// Whether the title shows its button: Play Games can run here.
    var hasDashboard: Bool { Self.service.hasDashboard }

    /// Whether a Level Designer picture can credit the player. Off on
    /// Android by decision (2026-11-13: no maker name or photo leaves an
    /// Android device), whoever is signed in; `creditsPlayer` is the switch.
    var canCredit: Bool { (Self.creditsPlayer && Self.service.isSignedIn) || LaunchArguments.sharePlayerName != nil }

    /// Whether a signed-in player's Play Games name and picture credit a
    /// level they share, as Game Center's do on iOS. Built, and off: turning
    /// it on adds Name and Photos to the Data safety answers
    /// (`Tools/Play/PLAY-CONSOLE-SETUP.md` §4).
    static let creditsPlayer = false

    /// The signed-in player's Play Games name and picture, while
    /// `creditsPlayer` allows it.
    func localPlayer() async -> (name: String, photo: UIImage?)? {
        if let name = LaunchArguments.sharePlayerName { return (name, nil) }
        guard Self.creditsPlayer, let player = await Self.service.localPlayer() else { return nil }
        return (player.name, player.photo.flatMap(UIImage.init(data:)))
    }

    /// Opens Play Games' achievements, signing the player in first if they
    /// aren't.
    func showDashboard(over window: UIWindow?) {
        Self.service.showDashboard()
    }

    /// Reports the board firsts in a move the player just made.
    func played(from previous: GameState, to next: GameState) {
        let new = Achievement.moments(from: previous, to: next).subtracting(moments)
        guard !new.isEmpty else { return }
        moments.formUnion(new)
        ICloudSyncManager.shared.insert(new.map(\.rawValue), intoSetForKey: Key.moments)
        report(showingBanners: true)
    }

    /// Reports progress after a level is cleared for the first time.
    func clearedLevel() {
        report(showingBanners: true)
    }

    /// Another device had board firsts or cleared levels: reports what they
    /// earned, quietly (that device showed the banners).
    func savedDataDidSync(_ keys: Set<String>) {
        guard keys.contains(Key.moments) || Progress.isAffected(by: keys) else { return }
        moments = Self.savedMoments()
        report(showingBanners: false)
    }

    private func answeredFirst() {
        if !hasAnswered {
            hasAnswered = true
            let handlers = answerHandlers
            answerHandlers.removeAll()
            handlers.forEach { $0() }
        }
        Task { await catchUp() }
    }

    /// Loads what the service holds, then quietly sends what it is missing.
    private func catchUp() async {
        reported = [:]
        if LaunchArguments.resetsAchievements, await Self.service.reset() {
            // Start over completely, board firsts included.
            moments = []
            ICloudSyncManager.shared.resetSet(forKey: Key.moments)
        } else {
            reported = await Self.service.load()
        }
        report(showingBanners: false)
    }

    /// Sends every achievement that has moved past what the service holds.
    private func report(showingBanners: Bool) {
        var progressed: [String: Double] = [:]
        for achievement in Achievement.all {
            let percent = achievement.percentComplete(moments: moments)
            if percent > reported[achievement.id, default: 0] { progressed[achievement.id] = percent }
        }
        guard !progressed.isEmpty else { return }
        for (id, percent) in progressed {
            reported[id] = percent
        }
        Task {
            guard await Self.service.report(progressed, showingBanners: showingBanners) else {
                // Forget what didn't arrive, so the next report sends it again.
                await MainActor.run {
                    for id in progressed.keys { self.reported[id] = nil }
                }
                return
            }
        }
    }
}
