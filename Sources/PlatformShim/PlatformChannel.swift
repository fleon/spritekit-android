import Foundation

/// The game's line to Google Play and the device: Play Billing, Play Games
/// Services and the device glue, all of which live in Java in the app.
///
/// One call each way, both JSON:
///
///   - `call("billing.purchase", ["productId": …])` reaches Java at once on
///     the game's thread. Anything slow is started there and answered later.
///   - Java's answers and news come back as **events**, each
///     `{"service": …, "event": …, …}`. Java queues them and flips a flag;
///     the frame loop sees it and hands the batch to `deliver(_:)`, so every
///     handler runs on the game's thread, never on one of Java's.
///
/// Everything above this — what is owned, which achievements moved, how
/// saved data merges — is decided in Swift and tested on the Mac against a
/// channel whose transport is a test double; the shell installs the JNI one.
public final class PlatformChannel {
    public typealias Message = [String: Any]
    public typealias Handler = (_ event: String, _ body: Message) -> Void

    /// The channel the shell installed, if the app runs where there is one.
    nonisolated(unsafe) public static var shared: PlatformChannel?

    private let send: (_ name: String, _ arguments: Data) -> Data?
    private var handlers: [String: [Handler]] = [:]

    /// `send` makes the call: the arguments as JSON bytes in, the immediate
    /// answer's bytes (or nil) out.
    public init(send: @escaping (_ name: String, _ arguments: Data) -> Data?) {
        self.send = send
    }

    /// Calls `name` (`service.method`) with `arguments`. Returns what Java
    /// knew at once, if anything.
    @discardableResult
    public func call(_ name: String, _ arguments: Message = [:]) -> Message? {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments) else { return nil }
        guard let answer = send(name, data), !answer.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: answer)) as? Message
    }

    /// Listens to one service's events.
    public func on(_ service: String, _ handler: @escaping Handler) {
        handlers[service, default: []].append(handler)
    }

    /// Hands a batch of events (a JSON array) to their services.
    public func deliver(_ batch: Data) {
        guard let events = (try? JSONSerialization.jsonObject(with: batch)) as? [Message] else { return }
        deliver(events)
    }

    public func deliver(_ events: [Message]) {
        for event in events {
            guard let service = event["service"] as? String, let name = event["event"] as? String else { continue }
            for handler in handlers[service] ?? [] {
                handler(name, event)
            }
        }
    }
}

public extension PlatformChannel.Message {
    /// JSON hands numbers back as `NSNumber` (Int or Double as it parsed),
    /// so these read either way.
    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        return (self[key] as? NSNumber)?.doubleValue
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        return double(key).map { Int($0) }
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        return (self[key] as? NSNumber)?.boolValue
    }
}
