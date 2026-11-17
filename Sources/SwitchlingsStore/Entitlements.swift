import Foundation

/// What the game keeps about the full game once a backend has spoken: what
/// is owned, when it was bought, and whether that was in time to keep the
/// secret worlds.
///
/// This is the half of `StoreManager` that has nothing to do with any store,
/// so it is here, tested on the host, rather than inside a body nobody can
/// run. It is Switchlings' own (its product, its launch event, its reward),
/// not the runtime's: it leaves with the game when the runtime moves to a
/// repository of its own.
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
