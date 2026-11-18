import Foundation
#if SPRITEKIT_SHIM
import PlatformShim
import SpriteKitShim
#else
import UIKit
#endif

/// The game's page in its store, opened for the player to rate it: the App
/// Store's write-a-review page on Apple platforms, the game's Google Play
/// page on Android (Play has no page that opens on its review form).
public enum StoreReviewPage {
    /// The page for the App Store app `appStoreID` (its numeric Apple ID),
    /// or on Android the game's Play page in `language` when given.
    public static func url(appStoreID: String, language: String? = nil) -> URL? {
        #if SPRITEKIT_SHIM
        PlayStorePage.url(language: language)
        #else
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
        #endif
    }

    /// Opens it. Returns whether there was a page to open.
    @discardableResult
    public static func open(appStoreID: String, language: String? = nil) -> Bool {
        #if os(tvOS)
        return false
        #else
        guard let url = url(appStoreID: appStoreID, language: language) else { return false }
        return SystemLinks.open(url)
        #endif
    }
}

/// Opens links outside the game: UIKit's on Apple platforms, the shell's on
/// Android, none on a host test (which sets its own).
public enum SystemLinks {
    public nonisolated(unsafe) static var open: (URL) -> Bool = { url in
        #if SPRITEKIT_SHIM && !canImport(Darwin)
        SystemServices.openURL(url)
        #elseif !SPRITEKIT_SHIM && !os(tvOS)
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
        return true
        #else
        false
        #endif
    }
}
