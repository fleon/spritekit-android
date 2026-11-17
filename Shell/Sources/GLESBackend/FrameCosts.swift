import Foundation
import ShellCore
import SpriteKitShim

/// Where a long frame's time went, logged with it (`frame cost …`): the
/// frame split into the scene's tick and its drawing, and the frame thread's
/// one-off work (texture uploads, programs built, bakes, waits for a page
/// still decoding). What made a loading screen's warm-up draw take seconds
/// on a phone was guesswork without it. Frame thread only; programs built on
/// `GLBuilderThread` aren't counted.
nonisolated enum FrameCosts {
    struct Tally {
        var milliseconds = 0.0
        var count = 0

        mutating func add(_ seconds: TimeInterval) {
            milliseconds += seconds * 1000
            count += 1
        }

        var text: String { "\(Int(milliseconds.rounded())) ms ×\(count)" }
    }

    enum Kind: Int, CaseIterable {
        case uploads, programs, programWaits, bakes, pageWaits
    }

    nonisolated(unsafe) private static var tallies = [Tally](repeating: Tally(), count: Kind.allCases.count)

    /// Times `work` as `kind`, on the frame thread; elsewhere just runs it.
    static func time<T>(_ kind: Kind, _ work: () -> T) -> T {
        guard Thread.isMainThread else { return work() }
        let started = MediaTime.source()
        let result = work()
        tallies[kind.rawValue].add(MediaTime.source() - started)
        return result
    }

    /// Adds `seconds` to `kind` (a wait timed elsewhere), on the frame thread.
    static func add(_ kind: Kind, _ seconds: TimeInterval) {
        guard Thread.isMainThread else { return }
        tallies[kind.rawValue].add(seconds)
    }

    static func reset() {
        tallies = [Tally](repeating: Tally(), count: Kind.allCases.count)
    }

    /// Logs the frame if it took `longFrame` or more.
    static func report(tick: TimeInterval, draw: TimeInterval) {
        let total = tick + draw
        guard total >= longFrame else { return }
        Log.info("frame cost \(Int((total * 1000).rounded())) ms: tick \(Int((tick * 1000).rounded())) ms, draw \(Int((draw * 1000).rounded())) ms; bakes \(tallies[Kind.bakes.rawValue].text), page waits \(tallies[Kind.pageWaits.rawValue].text), uploads \(tallies[Kind.uploads.rawValue].text), programs \(tallies[Kind.programs.rawValue].text), waits for programs \(tallies[Kind.programWaits.rawValue].text)")
    }

    static let longFrame: TimeInterval = 0.05
}
