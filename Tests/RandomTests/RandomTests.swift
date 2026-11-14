import CoreGraphics
import Foundation
import Testing

/// The game's `-RandomSeed`, which `Random` reads once; this test process
/// runs seeded throughout.
nonisolated enum LaunchArguments {
    static let randomSeed: UInt64? = 7
}

/// `Random`'s streams, seeded: each named stream draws one sequence, the same
/// every run and on every platform (`Tools/Capture/parity.js` compares the
/// iPhone and Android with `-RandomSeed`), whatever the others draw meanwhile.
@Suite struct RandomTests {
    /// A stream as the game draws from it, every kind of draw in turn.
    private static func draws(_ random: inout Random) -> [String] {
        var out: [String] = []
        for _ in 0..<4 {
            out.append("\(Int.random(in: 0..<1000, using: &random))")
            out.append("\(Double.random(in: 0...1, using: &random))")
            out.append("\(CGFloat.random(in: -2...2, using: &random))")
            out.append("\(Float.random(in: 0..<5, using: &random))")
            out.append("\(Bool.random(using: &random))")
            out.append("\([1, 2, 3, 4, 5].randomElement(using: &random) ?? 0)")
            out.append("\([1, 2, 3, 4, 5].shuffled(using: &random))")
        }
        return out
    }

    @Test func runsSeeded() {
        #expect(Random.isSeeded)
    }

    @Test func aStreamDrawsTheSameSequenceEveryTime() {
        for name in ["celebration", "lawn-garden", "ride-sparks", "title-tour", "circuit-led-3"] {
            var first = Random(name), second = Random(name)
            #expect(Self.draws(&first) == Self.draws(&second), "\(name)")
        }
    }

    @Test func streamsDontDisturbOneAnother() {
        var alone = Random("lawn-garden")
        let expected = Self.draws(&alone)
        // The same stream, its draws interleaved with others' on other threads.
        var lawn = Random("lawn-garden")
        let others = DispatchQueue(label: "others", attributes: .concurrent)
        let group = DispatchGroup()
        for name in ["lawn-farm", "seabed", "celebration"] {
            others.async(group: group) {
                var random = Random(name)
                _ = Self.draws(&random)
            }
        }
        let drawn = Self.draws(&lawn)
        group.wait()
        #expect(drawn == expected)
    }

    @Test func eachSubsystemHasItsOwnSequence() {
        var lawn = Random("lawn-garden"), farm = Random("lawn-farm")
        #expect(Self.draws(&lawn) != Self.draws(&farm))
    }

    /// The raw sequence is pinned, so a platform (or a toolchain) that drew
    /// differently would fail here rather than in the parity sweep.
    @Test func theSequenceIsPinned() {
        var random = Random("celebration")
        let raw = (0..<3).map { _ in random.next() }
        #expect(raw == Self.pinnedCelebration)
        var again = Random("celebration")
        #expect(Int.random(in: 0..<1000, using: &again) == Self.pinnedInt)
    }

    private static let pinnedCelebration: [UInt64] = [4_265_947_547_345_889_356, 11_378_222_587_123_308_350, 16_165_837_294_986_841_779]
    private static let pinnedInt = 231
}
