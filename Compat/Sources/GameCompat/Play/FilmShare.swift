import Foundation
import SpriteKitShim

/// A cleared level's Share, as the win card's runs it (`SolutionShare`'s
/// `onShare`), step for step: the line and link to send, the credit (someone
/// anonymous, as on iOS with Game Center signed out — Android has none), the
/// film built off the main thread (`SolutionFilm.build`), made while the
/// game's view takes turns with it, then the share sheet with the line, the
/// link and the file.
///
/// The win card itself, its dropdown and its form are the UI ring's; until
/// then `PlayScene` shows a Share button of its own and the form's three
/// choices come from launch arguments.
public enum FilmShare {
    /// The form's three choices (`ShareFormNode.Choices`), by their names.
    public struct Choices {
        public var picture: Bool
        public var smooth: Bool
        public var landscape: Bool
        public var includesLink: Bool

        public init(picture: Bool = false, smooth: Bool = true, landscape: Bool = false, includesLink: Bool = true) {
            self.picture = picture
            self.smooth = smooth
            self.landscape = landscape
            self.includesLink = includesLink
        }
    }

    /// The game's store page on Android: Google Play's, where iOS links the
    /// App Store's in the player's storefront (`SolutionShare.appStoreLink`).
    static let storeLink = URL(string: "https://play.google.com/store/apps/details?id=com.fleon.switchlings")

    /// Films `entry` cleared along `moves` and opens the share sheet, telling
    /// `progress` how far along it is, then `done` whether a file was shared.
    static func share(entry: LevelEntry, moves: [GameSession.Move], choices: Choices, view: SKView, from anchor: SKNode, progress: @escaping (CGFloat) -> Void, done: @escaping (URL?) -> Void) {
        guard let world = LevelCatalog.allWorlds.first(where: { $0.index == entry.worldIndex }) else { return done(nil) }
        let theme = world.theme
        let text = LocalizedString.shareCampaignMessage(world.displayName, entry.number).localized
        let code = "W\(world.isSecret ? 0 : world.index + 1) / L\(entry.number)"
        let name = "Switchlings \(LocalizedString.pauseSubtitle(world.displayName, entry.number).localized)"
        var attribution = SolutionShare.Attribution.anonymous(in: theme)
        attribution.caption = .shareClearedBy
        attribution.codeCaption = .shareLevel
        Task { @MainActor in
            guard let film = await SolutionFilm.build(
                level: entry.level, theme: theme, moves: moves,
                format: choices.picture ? .image : .video,
                frameRate: choices.smooth ? .smooth : .standard,
                orientation: choices.landscape ? .landscape : .portrait,
                name: name, code: code, attribution: attribution, view: view
            ) else { return done(nil) }
            view.isAsynchronous = false
            film.make(progress: progress) { url in
                view.isAsynchronous = true
                // Held until now by this closure, which the film keeps while it works.
                _ = film
                guard let url else { return done(nil) }
                let link = choices.includesLink ? storeLink : nil
                ShareSheet.present(([text, link, url] as [Any?]).compactMap { $0 }, from: anchor)
                done(url)
            }
        }
    }
}
