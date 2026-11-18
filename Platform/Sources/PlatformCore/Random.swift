import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// Where a game's random draws come from: each subsystem keeps a stream,
/// `var random = Random("celebration")`, and draws with `using: &random`.
/// Unseeded, a stream is the system's generator, as `random(in:)` alone is.
/// Seeded (`Random.seed`, which a debug build sets from a launch argument
/// before drawing anything), each stream is a SplitMix64 of its own, started
/// from the seed and its name, so two runs on any platform draw alike,
/// whatever order threads reach the streams in: what lets an Apple build
/// and an Android one be captured frame for frame side by side.
public nonisolated struct Random: RandomNumberGenerator {
    /// The run's seed, if it has one. Set it once, at launch, before any
    /// stream is made.
    public nonisolated(unsafe) static var seed: UInt64?
    public static var isSeeded: Bool { seed != nil }

    private var state: UInt64?

    public init(_ name: String) {
        state = Self.seed.map { Self.mix($0 ^ Self.hash(name)) }
    }

    public mutating func next() -> UInt64 {
        guard var state else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        state &+= 0x9E37_79B9_7F4A_7C15
        self.state = state
        return Self.mix(state)
    }

    /// SplitMix64's output function.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the name's UTF-8, the same on every platform (Swift's own
    /// hashing is seeded afresh each run).
    private static func hash(_ name: String) -> UInt64 {
        name.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

extension Random {
    /// `SKAction.wait(forDuration:withRange:)`, whose draw SpriteKit makes
    /// itself: seeded, the wait is drawn here instead, once.
    public mutating func wait(forDuration duration: TimeInterval, withRange range: TimeInterval) -> SKAction {
        guard state != nil, range > 0 else { return .wait(forDuration: duration, withRange: range) }
        return .wait(forDuration: max(0, duration + TimeInterval.random(in: -range / 2...range / 2, using: &self)))
    }
}
