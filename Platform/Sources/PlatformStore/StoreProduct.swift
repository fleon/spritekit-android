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

    public var id: String
    public var kind: Kind

    public init(_ id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func nonConsumable(_ id: String) -> StoreProduct {
        StoreProduct(id, kind: .nonConsumable)
    }

    public static func consumable(_ id: String) -> StoreProduct {
        StoreProduct(id, kind: .consumable)
    }
}

public extension Collection where Element == StoreProduct {
    var ids: [String] { map(\.id) }
    var consumableIDs: Set<String> { Set(filter { $0.kind == .consumable }.map(\.id)) }
}

public extension SimulatedBilling {
    /// Simulated purchases of these products, consumables and all.
    convenience init(products: [StoreProduct], defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, consumables: products.consumableIDs)
    }
}
