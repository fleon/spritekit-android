import Foundation

/// Play In-App Review, behind StoreKit's `SKStoreReviewController` (the
/// `StoreKit` module): the game asks for a rating, and Play decides whether
/// its card shows, as the App Store does on iOS.
///
/// Neither store tells the game what the player did, or whether anything
/// showed — Play quotas the card per player and says nothing about it — so
/// a request is fire-and-forget here too, and a game's own rules about when
/// to ask (Zyl asks at level milestones) stay its own. Java hears
/// `review.request` and answers `requested {ok}` once Play's flow is over,
/// which only says the request ran; while one is running, another is
/// dropped, as Play would drop it.
public final class PlayInAppReview {
    private static let service = "review"

    private let channel: PlatformChannel
    /// A request is with Play now.
    public private(set) var isRequesting = false

    public init(channel: PlatformChannel) {
        self.channel = channel
        channel.on(Self.service) { [weak self] event, _ in
            if event == "requested" { self?.isRequesting = false }
        }
    }

    public func request() {
        guard !isRequesting else { return }
        isRequesting = true
        channel.call("review.request")
    }
}

public enum StoreReview {
    /// Play In-App Review over the shell's channel; nil where there is none
    /// (a host build), where a request does nothing, as on a simulator.
    nonisolated(unsafe) public static var playInAppReview: PlayInAppReview? = PlatformChannel.shared.map(PlayInAppReview.init)

    /// Asks for a rating, if anything can show one.
    public static func request() {
        playInAppReview?.request()
    }
}
