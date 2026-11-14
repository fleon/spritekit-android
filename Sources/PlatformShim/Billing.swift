import Foundation

/// Buying the full game, with StoreKit taken out from under `StoreManager`.
///
/// The entitlement — whether the full game is owned — is kept on the device
/// (`Entitlements`), read before anything asks a service, so every lock,
/// padlock, offer and secret-world rule is right offline and at launch.
/// Behind it sits one of three backends: `PlayBilling` (Google Play, through
/// `PlatformChannel`), `SimulatedBilling` (the Apple build's
/// `-SimulatePurchases`: granted locally, no money moves) or `NoBilling`
/// (no store at all, as on a host test).
public protocol BillingBackend: AnyObject {
    /// The product's price in the player's currency, once it is known.
    var displayPrice: String? { get }
    /// Products the player owns, as the service reports them.
    var ownedProducts: Set<String> { get }
    /// Products that cost nothing where the player shops (China mainland).
    var freeProducts: Set<String> { get }
    /// Loads prices and entitlements. Calls `changed` whenever either moves.
    func start(changed: @escaping () -> Void)
    func purchase(_ productID: String) async -> BillingResult
    /// Asks the service to hand back what the player already owns.
    func restore() async -> Bool
    /// When each owned product was first bought, where the service says:
    /// what the launch event's rule reads, in place of `Date()`.
    var purchaseDates: [String: Date] { get }
}

public extension BillingBackend {
    var purchaseDates: [String: Date] { [:] }
}

public enum BillingResult: Sendable {
    case purchased
    case pending
    case cancelled
    case failed
}

/// No billing service: nothing is owned, nothing has a price, and a purchase
/// fails rather than quietly succeeding. What an Android build uses when
/// purchases are not simulated — honest about having no store behind it.
public final class NoBilling: BillingBackend {
    public var displayPrice: String? { nil }
    public var ownedProducts: Set<String> { [] }
    public var freeProducts: Set<String> { [] }

    public init() {}

    public func start(changed: @escaping () -> Void) {}
    public func purchase(_ productID: String) async -> BillingResult { .failed }
    public func restore() async -> Bool { false }
}

/// Grants the purchase on this device at once, without a service, and keeps
/// it across launches. The Apple build's `-SimulatePurchases` with somewhere
/// to put the result.
public final class SimulatedBilling: BillingBackend {
    private enum Key {
        static let simulated = "store.simulatedProducts"
    }

    /// The full game's US price, as `-PreviewPrices` shows it when StoreKit
    /// has no products.
    public static let previewPrice = "$6.99"

    private let defaults: UserDefaults
    private var changed: (() -> Void)?
    private var granted: Set<String>

    public var displayPrice: String? { Self.previewPrice }
    public var ownedProducts: Set<String> { granted }
    public var freeProducts: Set<String> { [] }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        granted = Set(defaults.stringArray(forKey: Key.simulated) ?? [])
    }

    public func start(changed: @escaping () -> Void) {
        self.changed = changed
    }

    public func purchase(_ productID: String) async -> BillingResult {
        guard !granted.contains(productID) else { return .purchased }
        granted.insert(productID)
        defaults.set(granted.sorted(), forKey: Key.simulated)
        changed?()
        return .purchased
    }

    public func restore() async -> Bool {
        changed?()
        return !granted.isEmpty
    }

    /// Takes the simulated purchase back, so the free game can be walked
    /// through again without clearing the app's data.
    public func forgetPurchases() {
        granted = []
        defaults.removeObject(forKey: Key.simulated)
        changed?()
    }
}

/// What the game keeps about the full game once a backend has spoken: what
/// is owned, when it was bought, and whether that was in time to keep the
/// secret worlds.
///
/// This is the half of `StoreManager` that has nothing to do with any store,
/// so it is here, tested on the host, rather than inside a body nobody can
/// run.
public struct Entitlements {
    public enum Key {
        public static let owned = "store.ownedProducts"
        public static let free = "store.freeProducts"
        /// When the full game was first bought.
        public static let boughtAt = "store.fullGameBoughtAt"
        /// Seen owned, with no purchase date, during the launch event.
        public static let ownedInEvent = "store.ownedDuringLaunchEvent"
        /// The player has been told The Mainframe is their reward.
        public static let rewardAnnounced = "store.mainframeRewardAnnounced"
        /// The player claimed the pre-registration reward (its Claim button).
        public static let rewardClaimed = "store.mainframeRewardClaimed"
    }

    public static let fullGameID = "com.fleon.switchlings.fullgame"
    /// Play's pre-registration reward: a one-time product Play grants free
    /// to whoever pre-registered, never sold in the game. Owning it keeps the
    /// secret worlds for good, with or without the full game.
    public static let mainframeRewardID = "com.fleon.switchlings.mainframe"

    /// When the launch event ends, and with it the chance to keep the secret
    /// worlds: as its App Store In-App Event does, 14 February 2027 at
    /// midnight, GMT+1. The same instant on both platforms, deliberately —
    /// a player who owns the game on one keeps the worlds on the other.
    public static let launchEventEnd = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 3600), year: 2027, month: 2, day: 14
    ).date ?? .distantFuture

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var owned: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.owned) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.owned) }
    }

    public var free: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.free) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.free) }
    }

    /// Keeps when the full game was first bought; the earliest wins, so a
    /// later report cannot push a player out of the launch event.
    public func noteBought(at date: Date) {
        let earlier = (defaults.object(forKey: Key.boughtAt) as? Date).map { min($0, date) }
        defaults.set(earlier ?? date, forKey: Key.boughtAt)
    }

    public var boughtAt: Date? { defaults.object(forKey: Key.boughtAt) as? Date }

    /// Owned with no purchase date while the event runs (free here, or
    /// simulated): the secret worlds are kept.
    public func noteOwnedDuringEvent(owns: Bool, eventRunning: Bool) {
        guard owns, eventRunning, boughtAt == nil else { return }
        defaults.set(true, forKey: Key.ownedInEvent)
    }

    public var wasOwnedDuringEvent: Bool { defaults.bool(forKey: Key.ownedInEvent) }

    /// Whether the player has been told about the pre-registration reward.
    public var rewardAnnounced: Bool {
        get { defaults.bool(forKey: Key.rewardAnnounced) }
        nonmutating set { defaults.set(newValue, forKey: Key.rewardAnnounced) }
    }

    /// Whether the player has claimed the pre-registration reward.
    public var rewardClaimed: Bool {
        get { defaults.bool(forKey: Key.rewardClaimed) }
        nonmutating set { defaults.set(newValue, forKey: Key.rewardClaimed) }
    }

    /// The pre-registration reward counts once claimed, or once the launch
    /// event is over (when nothing offers the claim any more).
    public func rewardCounts(owned: Bool, eventRunning: Bool) -> Bool {
        owned && (rewardClaimed || !eventRunning)
    }

    /// Whether the secret worlds are the player's for good: the
    /// pre-registration reward (`rewarded`), or the full game owned in time.
    public func keepsSecretWorlds(owns: Bool, rewarded: Bool = false) -> Bool {
        if rewarded { return true }
        guard owns else { return false }
        if let boughtAt { return boughtAt <= Self.launchEventEnd }
        return wasOwnedDuringEvent
    }
}
