#if SPRITEKIT_SHIM
import Foundation
import PlatformAndroid
import PlatformDisplay
import PlatformGameCenter
import PlatformShim
import PlatformSprite
import PlatformStore
import PlatformSync
import SpriteKitShim

extension AndroidPlatformServices.Configuration {
    /// The toolkit's managers on Google Play and the device, as most games
    /// hand them: Play Games' achievements and leaderboards to
    /// `gameCenter`, Saved Games under `ICloudSyncManager` (`syncsSavedData`),
    /// Play Billing to `store` for its configured products, and with
    /// `statusBar` the settings' switch
    /// (`StatusBarSetting`) to the status bar. A manager left nil gets
    /// nothing. Set anything else (the player for GameKit's
    /// `GKLocalPlayer`, diagnostics) on the result before
    /// `AndroidPlatformServices.install`.
    public static func toolkit(
        gameCenter: GameCenterManager?,
        syncsSavedData: Bool = true,
        store: StoreManager? = nil,
        statusBar: Bool = false
    ) -> Self {
        var services = Self()
        if let gameCenter {
            services.achievements = { gameCenter.achievementService = $0 }
            services.leaderboards = { gameCenter.leaderboardService = $0 }
        }
        if syncsSavedData {
            services.cloud = { ICloudSyncManager.cloud = $0 }
        }
        if let store {
            services.billing = .init(store: store)
        }
        if statusBar {
            services.statusBar = .setting
        }
        return services
    }
}

extension AndroidPlatformServices.StatusBar {
    /// The settings' switch, `StatusBarSetting`.
    public static var setting: Self {
        .init(isVisible: { MainActor.assumeIsolated { StatusBarSetting.isVisible } }, changed: StatusBarSetting.didChange)
    }
}

extension AndroidPlatformServices.Billing {
    /// Play Billing for `store`'s products: its consumables, and those its
    /// server consumes, as its configuration lists them.
    public init(store: StoreManager) {
        let products = store.configuration.products
        let consumables = products.filter { $0.kind == .consumable }
        self.init(
            products: products.map(\.id),
            consumables: Set(consumables.map(\.id)),
            serverConsumed: Set(consumables.filter { $0.consumedBy == .server }.map(\.id))
        ) { store.billing = $0 }
    }
}

#if !canImport(Darwin)
// The splash is Android's and Apple's alone: a Mac host build has none.
extension DisplaySettings.Configuration {
    /// The display settings' defaults for a game with a launch splash: Auto
    /// never measures the splash, which says nothing of the game's scenes,
    /// and `-RenderScale 0.85` (debug builds) pins a scale nothing moves.
    public static var withLaunchSplash: Self {
        var configuration = Self()
        configuration.isMeasured = { $0 != nil && !($0 is StudioSplashScene) }
        configuration.pinnedRenderScale = { GameHostSurface.launchNumber("RenderScale") }
        return configuration
    }
}
#endif
#endif
