import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import UIKit
#if canImport(MessageUI)
import MessageUI
#endif
#endif

/// A feedback mail to the game's address, its subject and body the game's
/// own words: the system's mail sheet where the device has mail set up
/// (iPhone, iPad, the Mac), else a `mailto:` link the mail app opens
/// (Android, or no account). Apple TV has no mail.
public enum FeedbackMail {
    /// The `mailto:` link for the mail.
    public static func url(to address: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }

    /// Whether a mail can be written here at all.
    public static var isAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Writes the mail: in the mail sheet over `view`'s window where there's
    /// one, else through its `mailto:` link.
    public static func compose(to address: String, subject: String, body: String, over view: UIView? = nil) {
        #if os(tvOS)
        return
        #else
        #if canImport(MessageUI) && !SPRITEKIT_SHIM
        if MFMailComposeViewController.canSendMail(), let presenter = ShareSheet.presenter(for: view) {
            let sheet = MFMailComposeViewController()
            sheet.setToRecipients([address])
            sheet.setSubject(subject)
            sheet.setMessageBody(body, isHTML: false)
            sheet.mailComposeDelegate = MailSheetDismisser.shared
            presenter.present(sheet, animated: true)
            return
        }
        #endif
        guard let url = url(to: address, subject: subject, body: body) else { return }
        _ = SystemLinks.open(url)
        #endif
    }
}

#if canImport(MessageUI) && !SPRITEKIT_SHIM && !os(tvOS)
/// Closes the mail sheet once it's sent or cancelled.
private final class MailSheetDismisser: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = MailSheetDismisser()

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        MainActor.assumeIsolated { controller.dismiss(animated: true) }
    }
}
#endif
