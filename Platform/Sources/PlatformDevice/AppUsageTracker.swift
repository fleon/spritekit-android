import Foundation

/// How long the player has played, on every device: each device keeps its
/// own total under a key of its own (`<keyPrefix><device id>`), written at
/// most `checkpointInterval` apart while the game is in front, and the
/// total adds up every device's. Synced with the prefix as a `.latest`
/// prefix, no two devices ever write the same key, so nothing is lost.
///
/// A game starts it as it comes to the front and stops it as it leaves.
public final class AppUsageTracker {
    /// The tracker the game uses: replace it with one configured for the
    /// game before tracking starts.
    public static var shared = AppUsageTracker()

    private let storage: ValueStorage
    private let keyPrefix: String
    private let checkpointInterval: TimeInterval?
    private let now: () -> Date
    private let secondsKey: String
    private var activeSince: Date?
    private var checkpointTimer: Timer?

    /// `deviceKey` holds this device's id in `deviceDefaults`, which never
    /// sync (each device needs one of its own).
    public init(
        storage: ValueStorage = .standard,
        keyPrefix: String = "app.usage.seconds.",
        deviceKey: String = "app-usage.device-identifier",
        deviceDefaults: UserDefaults = .standard,
        checkpointInterval: TimeInterval? = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.keyPrefix = keyPrefix
        self.checkpointInterval = checkpointInterval
        self.now = now
        let device: String
        if let saved = deviceDefaults.string(forKey: deviceKey) {
            device = saved
        } else {
            device = UUID().uuidString
            deviceDefaults.set(device, forKey: deviceKey)
        }
        secondsKey = keyPrefix + device
    }

    /// Every device's play, this session's included and saved first.
    public var totalSeconds: TimeInterval {
        checkpoint()
        return storedSeconds
    }

    /// Every device's play, this session's counted without saving it (for a
    /// display that updates every frame).
    public var liveTotalSeconds: TimeInterval {
        storedSeconds + (activeSince.map { max(0, now().timeIntervalSince($0)) } ?? 0)
    }

    public var isTracking: Bool { activeSince != nil }

    public func startTracking() {
        guard activeSince == nil else { return }
        activeSince = now()
        checkpointTimer?.invalidate()
        guard let checkpointInterval else { return }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: checkpointInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpoint() }
        }
    }

    public func stopTracking() {
        checkpoint()
        activeSince = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    private var storedSeconds: TimeInterval {
        storage.keys().reduce(0) { total, key in
            guard key.hasPrefix(keyPrefix), let seconds = Self.seconds(storage.object(key)) else { return total }
            return total + seconds
        }
    }

    private func checkpoint() {
        guard let activeSince else { return }
        let now = now()
        let saved = Self.seconds(storage.object(secondsKey)) ?? 0
        storage.set(saved + max(0, now.timeIntervalSince(activeSince)), secondsKey)
        self.activeSince = now
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return (value as? NSNumber)?.doubleValue
    }
}
