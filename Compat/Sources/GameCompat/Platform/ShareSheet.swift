import Foundation
import PlatformShim
import SpriteKitShim

/// Android's body for `Source/Utils/ShareSheet.swift`: the same two calls,
/// for the same callers. The game's own file opens UIKit's
/// `UIActivityViewController` over the view's window; here the items are
/// sorted into what Android's `ACTION_SEND` takes (`ShareRequest`: the file,
/// and the line and link as its text) and handed to `SystemShare.sheet`,
/// which the shell installs: a JNI call into `MainActivity.shareFile`,
/// which starts the system chooser with a `content://` URI from
/// `FilmProvider`. There's no popover to point, so `node` only says which
/// scene asked. A campaign level's App Store link becomes the game's Google
/// Play page in the game's language (`PlayStorePage`).
enum ShareSheet {
    static var isAvailable: Bool { SystemShare.sheet != nil }

    /// Opens the share sheet with `items`.
    static func present(_ items: [Any], from node: SKNode) {
        guard let sheet = SystemShare.sheet, sheet(ShareRequest(items: items, storePage: PlayStorePage.url(language: Localization.current.rawValue))) else { return }
        Markers.note("share sheet")
    }

    static func copy(_ text: String) {
        SystemShare.pasteboard?(text)
    }
}
