import Foundation
import PlatformShim

/// `Source/Utils/StoreManager.swift` on Android: the same API for the same
/// 15 calling files, with Google Play Billing where StoreKit was.
///
/// The entitlement — whether the full game is owned — is kept on the device
/// (`Entitlements`) and read before anything asks Play, so `isUnlocked(_:)`,
/// `shows(_:)`, `isFullGameUnlocked` and `keepsSecretWorlds` are right at
/// launch and offline, and every lock, padlock, offer and launch-event rule
/// behaves as on Apple. The launch event's end is the same instant on both
/// platforms, and Play's `purchaseTime` stands in for StoreKit's
/// `originalPurchaseDate`, so a player who bought in time keeps the secret
/// worlds on a new phone too.
///
/// The backend is `PlayBilling` once the shell has a `PlatformChannel`
/// (`installPlatformServices`), `SimulatedBilling` under
/// `-SimulatePurchases` (as on Apple: granted locally, no money moves), and
/// `NoBilling` otherwise — a host test, where a purchase fails honestly.
///
/// Android's one rule of its own: Play's pre-registration reward
/// (`Entitlements.mainframeRewardID`, granted free by Play at first launch to
/// whoever pre-registered) keeps the secret worlds for good, even without
/// the full game, once claimed (the locked world's Claim, or its banner) or
/// once the launch event is over. `MainframeReward` tells the player once.
final class StoreManager {
    static let shared = StoreManager()
    /// Posted whenever prices or purchases change.
    static let didChange = Notification.Name("StoreManager.didChange")

    enum PurchaseResult {
        case purchased
        case pending
        case cancelled
        case failed

        init(_ result: BillingResult) {
            switch result {
            case .purchased: self = .purchased
            case .pending: self = .pending
            case .cancelled: self = .cancelled
            case .failed: self = .failed
            }
        }
    }

    /// Where purchases come from (see above).
    static var billing: BillingBackend = NoBilling()

    private static let fullGameID = Entitlements.fullGameID
    private static let launchEventEnd = Entitlements.launchEventEnd

    private let entitlements = Entitlements()
    /// What the backend last reported, cached as the Apple build caches
    /// StoreKit's answer, so locks are right before it has spoken.
    private var owned: Set<String>
    private var free: Set<String>

    private init() {
        owned = entitlements.owned
        free = entitlements.free
    }

    /// Loads prices and purchases, and keeps listening for changes made
    /// elsewhere (another device, a refund).
    func start() {
        Self.billing.start { [weak self] in
            Task { @MainActor in self?.backendChanged() }
        }
        backendChanged()
    }

    func isUnlocked(_ world: World) -> Bool {
        world.isSecret ? keepsSecretWorlds : world.index == 0 || isFullGameUnlocked
    }

    /// Whether the world list shows `world`: a secret world while the launch
    /// event runs, and afterwards only to those who keep it.
    func shows(_ world: World) -> Bool {
        !world.isSecret || isLaunchEventRunning || keepsSecretWorlds
    }

    /// The launch event is on: buying the full game now keeps the secret worlds.
    var isLaunchEventRunning: Bool {
        LaunchArguments.launchEventRunning ?? (Date() <= Self.launchEventEnd)
    }

    /// The secret worlds are the player's: the full game owned by the end of
    /// the launch event, Play's pre-registration reward (or every world
    /// unlocked for testing).
    var keepsSecretWorlds: Bool {
        if LaunchArguments.unlocksAllWorlds { return true }
        return entitlements.keepsSecretWorlds(
            owns: ownsFullGame,
            rewarded: entitlements.rewardCounts(owned: isRewarded, eventRunning: isLaunchEventRunning)
        )
    }

    /// Play granted the pre-registration reward.
    var isRewarded: Bool {
        owned.contains(Entitlements.mainframeRewardID)
    }

    /// The reward waits for its Claim button: granted, not yet claimed, while
    /// the launch event runs (afterwards it counts without one).
    var hasRewardToClaim: Bool {
        isRewarded && !entitlements.rewardClaimed && isLaunchEventRunning
    }

    /// Claims the reward: the secret worlds open at once.
    func claimReward() {
        guard hasRewardToClaim else { return }
        entitlements.rewardClaimed = true
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Every world is open: the full game bought (or unlocked for testing).
    var isFullGameUnlocked: Bool {
        LaunchArguments.unlocksAllWorlds || ownsFullGame
    }

    /// The full game's price in the player's currency, once Play has
    /// answered. Nil until then, as the Apple build shows no price until
    /// StoreKit answers.
    var fullGamePrice: String? {
        Self.billing.displayPrice ?? LaunchArguments.previewPrice
    }

    func purchaseFullGame() async -> PurchaseResult {
        let result = await Self.billing.purchase(Self.fullGameID)
        if case .purchased = result {
            entitlements.noteBought(at: Self.billing.purchaseDates[Self.fullGameID] ?? Date())
            backendChanged()
        }
        return PurchaseResult(result)
    }

    /// Asks the store to hand back what the player already owns. Returns
    /// whether the full game is owned afterwards.
    func restore() async -> Bool {
        _ = await Self.billing.restore()
        backendChanged()
        return owned.contains(Self.fullGameID)
    }

    /// Bought, free where the player shops, or simulated.
    private var ownsFullGame: Bool {
        if LaunchArguments.locksFullGame { return false }
        return owned.union(free).contains(Self.fullGameID)
    }

    /// Takes whatever the backend now reports and tells the screens.
    private func backendChanged() {
        let reported = Self.billing.ownedProducts
        let reportedFree = Self.billing.freeProducts
        let moved = reported != owned || reportedFree != free
        owned = reported
        free = reportedFree
        if moved {
            entitlements.owned = reported
            entitlements.free = reportedFree
        }
        // A purchase restored on a new device keeps the day it was bought.
        if let date = Self.billing.purchaseDates[Self.fullGameID] { entitlements.noteBought(at: date) }
        entitlements.noteOwnedDuringEvent(owns: ownsFullGame, eventRunning: isLaunchEventRunning)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
