import Foundation

/// Play In-App Review, behind StoreKit's `SKStoreReviewController` (the
/// `StoreKit` module): the game asks for a rating, and Play decides whether
/// its card shows, as the App Store does on iOS.
///
/// Neither store tells the game what the player did, or whether anything
/// showed — Play quotas the card per player and says nothing about it — so
/// a request is fire-and-forget here too, and a game's own rules about when
/// to ask (at milestones, say) stay its own. Java hears
/// `review.request` and answers `requested {ok}` once Play's flow is over,
/// which only says the request ran; while one is running, another is
/// dropped, as Play would drop it. A request with no answer after
/// `answerTimeout` (an app whose Java has no `review` service) no longer
/// holds the next one back.
public final class PlayInAppReview {
    private static let service = "review"

    /// How long a request may go unanswered before another is let through.
    public static let answerTimeout: TimeInterval = 60

    private let channel: PlatformChannel
    private let clock: () -> TimeInterval
    private var requestedAt: TimeInterval = 0
    /// A request is with Play now.
    public private(set) var isRequesting = false

    public init(channel: PlatformChannel, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.channel = channel
        self.clock = clock
        channel.on(Self.service) { [weak self] event, _ in
            if event == "requested" { self?.isRequesting = false }
        }
    }

    public func request() {
        let now = clock()
        guard !isRequesting || now - requestedAt >= Self.answerTimeout else { return }
        isRequesting = true
        requestedAt = now
        channel.call("review.request")
    }
}

public enum StoreReview {
    /// Play In-App Review over the shell's channel; nil where there is none
    /// (a host build), where a request does nothing, as on a simulator.
    nonisolated(unsafe) public static var playInAppReview: PlayInAppReview? = PlatformChannel.shared.map { PlayInAppReview(channel: $0) }

    /// Asks for a rating, if anything can show one.
    public static func request() {
        playInAppReview?.request()
    }
}
