import Foundation
#if SPRITEKIT_SHIM
import PlatformShim
#else
import StoreKit
import UIKit
#endif

/// When a game asks for a rating, and asking.
///
/// A prompt is one rule and the record of what it has asked, kept in
/// `storage` under `key`: the milestones it asked at (`[Int]`), or `true`
/// once a one-off has asked, and, if the game's own flow said "not now",
/// when it may ask again (`<key>.snoozedUntil`). The store decides whether
/// its card shows (the App Store, or Play In-App Review on Android) and
/// says nothing either way, so asking counts as asked.
///
/// A game with a flow of its own (asking whether the player enjoys the game
/// first) reads `isDue`, then calls `markRequested()` or `snooze(for:)`.
public final class ReviewPrompt {
    public enum Rule {
        /// Once at each milestone `progress` reaches (levels cleared, say),
        /// the lowest not yet asked at first.
        case milestones([Int], progress: () -> Int)
        /// Once, after `minimum` seconds of play, as `total` counts them (an
        /// `AppUsageTracker`'s `liveTotalSeconds`).
        case playTime(minimum: TimeInterval, total: () -> TimeInterval)
        /// Once, the first time `condition` holds.
        case once(_ condition: () -> Bool)
    }

    /// Asks the store for its card. Returns false where nothing can show
    /// one (no window scene, Apple TV, a host test), and the prompt then
    /// doesn't count it as asked.
    public static var requestReview: () -> Bool = platformRequest

    public let key: String
    private let rule: Rule
    private let storage: ValueStorage
    private let isEnabled: () -> Bool
    private let now: () -> Date

    /// `isEnabled` holds a prompt back altogether (a test mode, say).
    public init(
        key: String,
        rule: Rule,
        storage: ValueStorage = .standard,
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.key = key
        self.rule = rule
        self.storage = storage
        self.isEnabled = isEnabled
        self.now = now
    }

    private var snoozeKey: String { key + ".snoozedUntil" }

    /// The milestones asked at so far.
    public var askedMilestones: Set<Int> {
        Set((storage.object(key) as? [Any] ?? []).compactMap { $0 as? Int ?? ($0 as? NSNumber)?.intValue })
    }

    /// The milestone a request now would be for.
    public var pendingMilestone: Int? {
        guard case let .milestones(milestones, progress) = rule else { return nil }
        let reached = progress()
        let asked = askedMilestones
        return milestones.sorted().first { reached >= $0 && !asked.contains($0) }
    }

    public var isSnoozed: Bool {
        guard let until = storage.object(snoozeKey) as? TimeInterval else { return false }
        return now().timeIntervalSince1970 < until
    }

    /// Whether the rule says to ask now.
    public var isDue: Bool {
        guard isEnabled(), !isSnoozed else { return false }
        switch rule {
        case .milestones:
            return pendingMilestone != nil
        case let .playTime(minimum, total):
            return !hasAsked && total() >= minimum
        case let .once(condition):
            return !hasAsked && condition()
        }
    }

    private var hasAsked: Bool { storage.object(key) as? Bool ?? false }

    /// Records that the game asked now.
    public func markRequested() {
        switch rule {
        case .milestones:
            guard let milestone = pendingMilestone else { return }
            storage.set(askedMilestones.union([milestone]).sorted(), key)
        case .playTime, .once:
            storage.set(true, key)
        }
    }

    /// Holds the prompt back for `interval` (the player said "not now").
    public func snooze(for interval: TimeInterval) {
        storage.set(now().timeIntervalSince1970 + interval, snoozeKey)
    }

    /// Asks the store for its card if the rule says to, and records it.
    /// Returns whether it asked.
    @discardableResult
    public func requestIfDue() -> Bool {
        guard isDue, Self.requestReview() else { return false }
        markRequested()
        return true
    }

    private static func platformRequest() -> Bool {
        #if SPRITEKIT_SHIM
        guard StoreReview.playInAppReview != nil else { return false }
        StoreReview.request()
        return true
        #elseif os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return false }
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
        return true
        #else
        return false
        #endif
    }
}
