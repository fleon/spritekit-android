import Foundation
import PlatformShim
import SwitchlingsStore
import SpriteKit

/// Tells the player, once, that Play's pre-registration reward came in: The
/// Mainframe is theirs (`StoreManager.isRewarded`). Play's rules ask a game
/// to say so in the game itself, soon after the reward arrives.
///
/// It waits for the title or the world list, with nothing else over them,
/// and shows the game's own notice card (`AlertPopup`) there: Claim claims the
/// reward, as the world's locked page and its banner do, and opens the world
/// list on The Mainframe's page, as its link does (`WorldLink`); once the
/// launch event is over the reward needs no claiming, and the button is Play.
/// Close leaves the player where they are (the page's Claim still waits).
/// Android's back closes it too (`AndroidGameController.handleBack`).
@MainActor
enum MainframeReward {
    private static let entitlements = Entitlements()
    private static weak var view: SKView?
    private static weak var shown: AlertPopup?
    private static var isWaiting = false

    /// Starts watching for the reward; the controller calls it once.
    static func watch(_ view: SKView) {
        self.view = view
        NotificationCenter.default.addObserver(forName: StoreManager.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { check() }
        }
        check()
    }

    /// Closes the notice if it's up; whether it was.
    static func dismiss() -> Bool {
        guard let shown, !shown.isDismissing else { return false }
        shown.dismiss()
        return true
    }

    private static func check() {
        guard StoreManager.shared.isRewarded, !entitlements.rewardAnnounced, !isWaiting else { return }
        guard let view, let scene = view.scene, scene is TitleScene || scene is WorldSelectScene,
              !scene.children.contains(where: { $0 is OverlayNode })
        else {
            // Not a screen for it yet: look again shortly.
            isWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignSystem.worldLinkRetry) {
                isWaiting = false
                check()
            }
            return
        }
        entitlements.rewardAnnounced = true
        let world = LevelCatalog.secretWorlds.first
        let name = world?.displayName ?? Localization.content("The Mainframe")
        let message = String(format: Localization.string("android.reward.mainframe", fallback: "Thanks for pre-registering! Your reward is %@, a secret world that's yours to keep."), name)
        let claims = StoreManager.shared.hasRewardToClaim
        let notice = AlertPopup(
            message: message,
            confirmTitle: (claims ? LocalizedString.claim : .play).localized,
            cancelTitle: LocalizedString.close.localized,
            confirmStyle: .primary
        )
        notice.onConfirm = { [weak view] in
            StoreManager.shared.claimReward()
            guard let view else { return }
            TransitionManager.present(WorldLink.destination(world?.index), in: view)
        }
        notice.place(in: SceneLayout(scene: scene))
        scene.addChild(notice)
        notice.present()
        shown = notice
    }
}
