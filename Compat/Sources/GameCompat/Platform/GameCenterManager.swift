import Foundation
import PlatformShim
import UIKit

/// `Source/Utils/GameCenterManager.swift` on Android.
///
/// **What is real.** The bookkeeping. Board firsts are kept in the game's own
/// saved data as a synced set, exactly as on Apple; what the service already
/// holds is loaded, compared and only the achievements that have moved are
/// sent. That logic is the Apple file's, and it runs here against
/// `LocalAchievements`, which keeps the percentages on the device.
///
/// **What is not.** Play Games Services. It needs a Play Console game with
/// its achievements created and an OAuth client tied to the app's signing
/// certificate; the app has a package name and a store listing and nothing
/// else. So `isSignedIn` is false, the dashboard does not open, and nothing
/// reaches the network — which is half of why the Android build's Data
/// Safety answer is as short as it is.
///
/// **And one thing that is a decision, not a gap.** `localPlayer()` returns
/// nil for good. There is no Game Center on Android and the user chose not
/// to add a Play Games identity, so a level shared from Android carries no
/// maker name or photo: the whole Name/Photos half of the iOS Data Safety
/// answer drops away rather than carrying across.
final class GameCenterManager {
    static let shared = GameCenterManager()

    private enum Key {
        static let moments = "gameCenter.moments"
    }

    /// What the player's devices keep the same.
    static let syncedKeys: [String: ICloudSyncManager.Merge] = [Key.moments: .union]

    /// Where achievements go. Installing a Play Games backend is the whole
    /// of what reporting on Android would take.
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
    /// it. Nothing calls it: there is no sheet to present.
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

    /// Whether the player is signed in. False without a service, which every
    /// caller already handles: the game is built to stay playable signed out.
    var isSignedIn: Bool { Self.service.isSignedIn }

    /// Whether a Level Designer picture can credit the player. False on
    /// Android by decision, not by omission.
    var canCredit: Bool { isSignedIn || LaunchArguments.sharePlayerName != nil }

    /// The signed-in player's name and photo. Always nil here.
    func localPlayer() async -> (name: String, photo: UIImage?)? {
        if let name = LaunchArguments.sharePlayerName { return (name, nil) }
        return nil
    }

    /// Opens the service's dashboard. There is none.
    func showDashboard(over window: UIWindow?) {}

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
