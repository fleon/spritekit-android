import Foundation

/// `Source/Utils/PlaytestLog.swift` on Android: it does nothing, on purpose.
///
/// On iOS every build — debug, TestFlight and release alike — posts each
/// level cleared to the Level Designer's server, timed, with a replayable
/// log and the device's name. That is fine there: those features come out
/// before the App Store release, and TestFlight is not a public listing.
///
/// On Play it is not fine. An internal or closed track is a **distributed
/// build**, so anything it reports has to be declared in Data Safety. The
/// user settled this on 2026-11-13: the Android build does not report. See
/// "The beta's reporting is off on Android" in `Android/README.md` and §4 of
/// `Tools/Play/PLAY-CONSOLE-SETUP.md`.
///
/// This is not a stub waiting for a body. It is the decision, written where
/// the decision takes effect: `run(...)` hands back nil, so every
/// `playtest?.tapped(...)` in `GameScene` is a no-op without `GameScene`
/// changing a line, and `flush()` has nothing to flush. Nothing here opens a
/// `URLSession`, and nothing above it can make it.
final class PlaytestLog {
    static let shared = PlaytestLog()

    private init() {}

    /// Always nil: nothing is recorded, so there is no run to record into.
    func run(levelID: String, version: LevelCatalog.Version, resumed: [GameSession.Move]) -> PlaytestRun? {
        nil
    }

    /// Nothing is queued, so there is nothing to send.
    func flush() {}
}

/// Kept so `GameScene`'s `private var playtest: PlaytestRun?` compiles. It
/// is never made: `PlaytestLog.run` returns nil.
final class PlaytestRun {
    enum Pause {
        case menu
        case background
    }

    private init() {}

    func set(_ pause: Pause, isOn: Bool) {}
    func tapped(_ id: String, _ direction: Direction, moved: Bool, in session: GameSession) {}
    func undid() {}
    func restarted() {}
    func hinted(standing: Int, actor: String?) {}
    func caughtUp(_ moves: [GameSession.Move]) {}
    func replay() {}
    func leave() {}
}
