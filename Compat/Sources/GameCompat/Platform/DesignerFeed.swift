import Foundation

/// `Source/Utils/DesignerFeed.swift` on Android: it does nothing, on purpose.
///
/// Same decision as `PlaytestLog` — the beta's reporting is off on Android —
/// and the other half of it. On iOS every build fetches the Level Designer's
/// level feed at launch and swaps the catalog for it. Here the bundle's
/// levels are the levels, always.
///
/// `whenAnswered` is the one that matters: the launch splash waits on it
/// before building the first scene, so it must call back rather than never
/// answer. It answers at once, because there is nothing to wait for.
///
/// The server itself is still reached, as on iOS, for what stays after the
/// beta: the players' Level Designer shares a level (`LevelShare`: `POST
/// /levels`) and opens a friend's (`GET /levels/<code>`), and a level's link
/// is its page there (`/l/<code>`). Nothing here asks it for the feed or
/// sends it a solve. `-DesignerServer <url>` points a debug build at another,
/// as on iOS (`adb shell am start … --esa args -DesignerServer,http://10.0.2.2:46198`).
enum DesignerServer {
    private static let url = URL(string: "https://switchlings.fleon.com")

    static func endpoint(_ path: String) -> URL? {
        (LaunchArguments.designerServerURL ?? url)?.appendingPathComponent(path)
    }
}

final class DesignerFeed {
    static let shared = DesignerFeed()

    private init() {}

    func start() {}
    func refresh() {}

    /// Answers immediately: the launch splash holds for this, and nothing
    /// here is ever going to arrive.
    func whenAnswered(_ handler: @escaping () -> Void) {
        handler()
    }
}

/// Real one is the first 12 hex digits of a level's SHA-256, which names
/// what is being played so solve times follow a level when it moves. Its one
/// reader is `LevelCatalog.Version`, and the only thing that ever reads a
/// version is the solve log — so with no solve log there is nothing for a
/// fingerprint to follow, and nil is the honest answer rather than a hash
/// nobody looks at. The players' Level Designer needs a real SHA-256 for its
/// own ids; that ring brings one.
nonisolated enum LevelFingerprint {
    static func ofLevels(inWorldFile data: Data) -> [String]? { nil }
}
