#if SPRITEKIT_SHIM
import Foundation
import PlatformShim

public extension PlayBilling {
    /// Google Play Billing for these products, consumables and all.
    convenience init(channel: PlatformChannel, products: [StoreProduct], defaults: UserDefaults = .standard) {
        self.init(channel: channel, products: products.ids, consumables: products.consumableIDs,
                  serverConsumed: products.serverConsumedIDs, defaults: defaults)
    }
}
#endif
