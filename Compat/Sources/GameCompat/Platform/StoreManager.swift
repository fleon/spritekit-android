import Foundation
import PlatformShim

/// `Source/Utils/StoreManager.swift` on Android.
///
/// **What is real.** Everything above the store. The entitlement — whether
/// the full game is owned — is kept on the device and read before anything
/// asks a service, so `isUnlocked(_:)`, `shows(_:)`, `isFullGameUnlocked`
/// and `keepsSecretWorlds` all answer correctly and every lock, padlock,
/// offer and launch-event rule in the 15 calling files behaves as it does on
/// Apple. The launch event's end is the same instant on both platforms, so a
/// player who bought in time keeps the secret worlds wherever they play.
///
/// **What is not.** There is no Play Billing. `com.fleon.switchlings.fullgame`
/// has not been created in the Play Console, so there is no product to
/// query, no price to show and nothing to buy — and `Tools/Store/
/// apply_iap_prices.py` does not carry across either, because Play has its
/// own territories and price points. §6 of `Tools/Play/PLAY-CONSOLE-SETUP.md`
/// is what has to happen before any of this can be more than it is.
///
/// So `purchaseFullGame()` fails rather than quietly succeeding, unless the
/// build is running on `SimulatedBilling` — the Android side of the Apple
/// build's `-SimulatePurchases`, which grants the unlock locally and keeps
/// it across launches. Untested JNI pretending to be a purchase flow would
/// be worth less than this and far easier to mistake for working.
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

    /// Where purchases come from. The app installs `SimulatedBilling` when
    /// it wants the unlock flow walked through; left alone nothing is owned
    /// and nothing can be bought, which is the truth of an Android build
    /// today.
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
    /// the launch event (or every world unlocked for testing).
    var keepsSecretWorlds: Bool {
        if LaunchArguments.unlocksAllWorlds { return true }
        return entitlements.keepsSecretWorlds(owns: ownsFullGame)
    }

    /// Every world is open: the full game bought (or unlocked for testing).
    var isFullGameUnlocked: Bool {
        LaunchArguments.unlocksAllWorlds || ownsFullGame
    }

    /// The full game's localized price, once the store has loaded it. Nil
    /// with no store, which is what callers already handle — the Apple build
    /// shows no price until StoreKit answers.
    var fullGamePrice: String? {
        Self.billing.displayPrice ?? LaunchArguments.previewPrice
    }

    func purchaseFullGame() async -> PurchaseResult {
        let result = await Self.billing.purchase(Self.fullGameID)
        if case .purchased = result {
            entitlements.noteBought(at: Date())
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
        entitlements.noteOwnedDuringEvent(owns: ownsFullGame, eventRunning: isLaunchEventRunning)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
