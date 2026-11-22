import Foundation

/// The block observers an owner adds to a notification center, removed
/// together: on `removeAll()`, or when the bag goes (an owner keeps one as a
/// property, so its observers go with it). Foundation's center on every
/// platform, Android's included.
public final class ObserverBag {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        removeAll()
    }

    /// Adds a block observer, as `NotificationCenter.addObserver(forName:
    /// object:queue:using:)` does, and keeps it.
    public func observe(
        _ name: Notification.Name?, object: Any? = nil, queue: OperationQueue? = nil,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        tokens.append(center.addObserver(forName: name, object: object, queue: queue, using: block))
    }

    /// Keeps observers added elsewhere, to this bag's center.
    public func add(_ observers: [NSObjectProtocol]) {
        tokens += observers
    }

    public func removeAll() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
