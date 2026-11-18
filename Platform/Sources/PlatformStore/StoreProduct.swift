import Foundation

// The service protocols the manager sits on come with it.
@_exported import PlatformServices

/// A product a game sells, by its store ID (the same on the App Store and
/// Google Play), and whether it is owned or used up.
public struct StoreProduct: Hashable, Sendable {
    public enum Kind: Sendable {
        /// Bought once and owned for good (an unlock).
        case nonConsumable
        /// Used up and bought again (a pack of hints): never owned, but
        /// delivered once a purchase.
        case consumable
    }

    /// Who uses up a consumable bought on Google Play.
    public enum Consumer: Sendable {
        /// The app, once it has delivered it.
        case client
        /// The game's server, once it has credited it (`confirm`): the app
        /// neither consumes nor acknowledges it. StoreKit has no consuming,
        /// so on Apple both finish the transaction alike.
        case server
    }

    public var id: String
    public var kind: Kind
    /// For a consumable: who consumes it on Google Play.
    public var consumedBy: Consumer

    public init(_ id: String, kind: Kind, consumedBy: Consumer = .client) {
        self.id = id
        self.kind = kind
        self.consumedBy = consumedBy
    }

    public static func nonConsumable(_ id: String) -> StoreProduct {
        StoreProduct(id, kind: .nonConsumable)
    }

    public static func consumable(_ id: String, consumedBy: Consumer = .client) -> StoreProduct {
        StoreProduct(id, kind: .consumable, consumedBy: consumedBy)
    }
}

public extension Collection where Element == StoreProduct {
    var ids: [String] { map(\.id) }
    var consumableIDs: Set<String> { Set(filter { $0.kind == .consumable }.map(\.id)) }
    /// The consumables the game's server consumes on Google Play.
    var serverConsumedIDs: Set<String> { Set(filter { $0.kind == .consumable && $0.consumedBy == .server }.map(\.id)) }
}

public extension SimulatedBilling {
    /// Simulated purchases of these products, consumables and all.
    convenience init(products: [StoreProduct], defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, consumables: products.consumableIDs)
    }
}
