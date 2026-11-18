import Foundation
import PlatformSprite
#if SPRITEKIT_SHIM
import PlatformShim
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// The system's share sheet and pasteboard, opened from a node in a scene.
///
/// On Apple platforms the sheet is `UIActivityViewController`, over the
/// view's window, opening as a popover pointed at the node where it opens
/// as one (iPad, the Mac). On Android the items are sorted into what
/// `ACTION_SEND` takes (`ShareRequest`) and handed to the shell's
/// `SystemShare.sheet`; an App Store link among them becomes the game's
/// Google Play page (`PlayStorePage`). Apple TV has neither.
public enum ShareSheet {
    /// Told each time a sheet opens (a recording's marker, say).
    public nonisolated(unsafe) static var didPresent: (() -> Void)?
    /// Android: the language (BCP 47) the game's Play Store page is linked
    /// in, in place of an App Store link; nil for Play's own choice.
    public nonisolated(unsafe) static var storePageLanguage: () -> String? = { nil }

    /// Whether there's a share sheet and a pasteboard to offer.
    public static var isAvailable: Bool {
        #if SPRITEKIT_SHIM
        SystemShare.sheet != nil
        #elseif os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Opens the share sheet with `items`: strings, web links and file URLs.
    /// `node` says which scene asked, and where a popover points (its
    /// `RestingBounds` where it has them, else its position).
    public static func present(_ items: [Any], from node: SKNode) {
        #if SPRITEKIT_SHIM
        let request = ShareRequest(items: items, storePage: PlayStorePage.url(language: storePageLanguage()))
        guard let sheet = SystemShare.sheet, sheet(request) else { return }
        didPresent?()
        #elseif !os(tvOS)
        guard let scene = node.scene, let view = scene.view, let controller = presenter(for: view) else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            let bounds = (node as? RestingBounds)?.restingBounds ?? .zero
            popover.sourceRect = viewFrame(of: bounds, in: node, scene: scene) ?? CGRect(origin: view.center, size: .zero)
        }
        controller.present(sheet, animated: true)
        didPresent?()
        #endif
    }

    /// Puts `text` on the pasteboard.
    public static func copy(_ text: String) {
        #if SPRITEKIT_SHIM
        SystemShare.pasteboard?(text)
        #elseif !os(tvOS)
        UIPasteboard.general.string = text
        #endif
    }

    #if !SPRITEKIT_SHIM
    /// The view controller on top of `view`'s window, which presents sheets.
    static func presenter(for view: UIView?) -> UIViewController? {
        let window = view?.window ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var controller = window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }

    /// `frame` (in `node`'s own space) in the view's coordinates.
    private static func viewFrame(of frame: CGRect, in node: SKNode, scene: SKScene) -> CGRect? {
        guard node.scene === scene else { return nil }
        let a = scene.convertPoint(toView: scene.convert(CGPoint(x: frame.minX, y: frame.minY), from: node))
        let b = scene.convertPoint(toView: scene.convert(CGPoint(x: frame.maxX, y: frame.maxY), from: node))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    #endif
}
