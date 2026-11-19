#if SPRITEKIT_SHIM
import Foundation

/// A code point's Bidi_Class (UAX #9, table 4).
enum BidiClass: UInt8, Sendable {
    case l, r, al, en, es, et, an, cs, nsm, bn, b, s, ws, on, lre, lro, rle, rlo, pdf, lri, rli, fsi, pdi
}

/// The Unicode bidirectional algorithm (UAX #9) for one line of text, as
/// Core Text applies it (`BidiTests`, `BidiParityTests`):
///
/// - **Base direction**: the first strong character's (P2, P3: L, or R and
///   AL), else left to right. A line broken out of a paragraph takes its
///   paragraph's by starting with a left-to-right or right-to-left mark
///   (U+200E, U+200F), which is a strong character of that direction and
///   draws nothing (`Bidi.marked`).
/// - **Levels**: the weak types resolved (W1 to W7: marks take their
///   base's type, European digits after Arabic letters are Arabic digits, a
///   single separator between two numbers joins them, terminators next to a
///   number join it), neutrals take the direction of the strong text both
///   sides (N1), else the line's (N2), then each character's level from its
///   type (I1, I2), and the whitespace a line ends on back at the line's
///   level (L1).
/// - **Order**: from the highest level down to the lowest odd one, every
///   stretch at or above that level reversed (L2).
///
/// Explicit embeddings, overrides and isolates (U+202A to U+202E, U+2066
/// to U+2069) are dropped, as X9 drops them from what the rules see; text
/// in a game hardly has them.
public enum Bidi {
    public enum Direction: Sendable, Equatable {
        case leftToRight, rightToLeft

        /// The level a paragraph in this direction is at.
        var level: UInt8 { self == .rightToLeft ? 1 : 0 }
    }

    static func bidiClass(_ scalar: Unicode.Scalar) -> BidiClass {
        let value = scalar.value
        // Most text is ASCII letters: a quick answer before the search.
        if (0x41 ... 0x5A).contains(value) || (0x61 ... 0x7A).contains(value) { return .l }
        var low = 0, high = classRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = classRanges[middle]
            if value < range.0 {
                high = middle - 1
            } else if value > range.1 {
                low = middle + 1
            } else {
                return range.2
            }
        }
        return .l
    }

    /// Whether `scalar` is whitespace to the algorithm (WS), which a line
    /// ends on at the line's own level (L1).
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool { bidiClass(scalar) == .ws }

    /// Whether `text` has anything that could be laid out other than left to
    /// right: a right-to-left letter, an Arabic digit or a direction mark.
    /// Text without is laid out exactly as it always was.
    public static func needsReordering(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0x0590 {
            switch bidiClass(scalar) {
            case .r, .al, .an, .rle, .rlo, .rli, .fsi: return true
            default: continue
            }
        }
        return false
    }

    /// The direction of `text`'s first strong character (P2, P3), or nil
    /// when it has none.
    public static func firstStrongDirection(_ text: String) -> Direction? {
        for scalar in text.unicodeScalars {
            switch bidiClass(scalar) {
            case .l: return .leftToRight
            case .r, .al: return .rightToLeft
            default: continue
            }
        }
        return nil
    }

    /// A paragraph's direction: its first strong character's, else left
    /// to right.
    public static func direction(of paragraph: String) -> Direction {
        firstStrongDirection(paragraph) ?? .leftToRight
    }

    /// `line` as a line of a paragraph in `direction`: led by the mark of
    /// that direction when its own first strong character says otherwise
    /// (or it has none and the paragraph is right to left), so laying it out
    /// alone gives it the paragraph's direction. Unchanged otherwise.
    public static func marked(_ line: String, in direction: Direction) -> String {
        let own = firstStrongDirection(line)
        if own == direction || (own == nil && direction == .leftToRight) { return line }
        return (direction == .rightToLeft ? "\u{200F}" : "\u{200E}") + line
    }

    /// Each scalar's level, and the line's, for `scalars` laid out as one
    /// line in their own direction (P2, P3).
    public static func levels(_ scalars: [Unicode.Scalar]) -> (levels: [UInt8], line: UInt8) {
        let classes = scalars.map(bidiClass)
        let base: UInt8 = classes.first(where: { $0 == .l || $0 == .r || $0 == .al }).map { $0 == .l ? 0 : 1 } ?? 0
        return (resolve(classes, base: base), base)
    }

    /// The order to draw items in, left to right, given each one's level
    /// (L2): indices into `levels`.
    public static func visualOrder(_ levels: [UInt8]) -> [Int] {
        var order = Array(levels.indices)
        guard let highest = levels.max(), let lowestOdd = levels.filter({ $0 % 2 == 1 }).min() else { return order }
        var level = highest
        while level >= lowestOdd {
            var index = 0
            while index < order.count {
                guard levels[order[index]] >= level else { index += 1; continue }
                var end = index
                while end + 1 < order.count, levels[order[end + 1]] >= level { end += 1 }
                order[index ... end].reverse()
                index = end + 1
            }
            if level == 0 { break }
            level -= 1
        }
        return order
    }

    // MARK: Resolving

    private static func isStrong(_ type: BidiClass) -> Bool { type == .l || type == .r || type == .al }

    private static func isRemoved(_ type: BidiClass) -> Bool {
        switch type {
        case .bn, .lre, .lro, .rle, .rlo, .pdf, .lri, .rli, .fsi, .pdi: return true
        default: return false
        }
    }

    private static func isNeutral(_ type: BidiClass) -> Bool {
        type == .b || type == .s || type == .ws || type == .on
    }

    /// W1 to I2 over one line at `base`, then L1.
    static func resolve(_ classes: [BidiClass], base: UInt8) -> [UInt8] {
        let count = classes.count
        guard count > 0 else { return [] }
        let embedding: BidiClass = base % 2 == 0 ? .l : .r
        // The characters the rules see (X9 drops the rest).
        let kept = classes.indices.filter { !isRemoved(classes[$0]) }
        var types = kept.map { classes[$0] }

        // W1: a mark takes the type before it (the line's at its start).
        for i in types.indices where types[i] == .nsm {
            types[i] = i == 0 ? embedding : types[i - 1]
        }
        // W2: a European digit after Arabic letters is an Arabic one.
        var lastStrong = embedding
        for i in types.indices {
            if isStrong(types[i]) { lastStrong = types[i] }
            if types[i] == .en, lastStrong == .al { types[i] = .an }
        }
        // W3: Arabic letters are right to left.
        for i in types.indices where types[i] == .al { types[i] = .r }
        // W4: one separator between two numbers of a kind joins them.
        if types.count >= 3 {
            for i in 1 ..< types.count - 1 {
                let before = types[i - 1], after = types[i + 1]
                if types[i] == .es, before == .en, after == .en { types[i] = .en }
                if types[i] == .cs, before == after, before == .en || before == .an { types[i] = before }
            }
        }
        // W5: terminators next to a European digit become digits.
        var i = 0
        while i < types.count {
            guard types[i] == .et else { i += 1; continue }
            var end = i
            while end + 1 < types.count, types[end + 1] == .et { end += 1 }
            let touches = (i > 0 && types[i - 1] == .en) || (end + 1 < types.count && types[end + 1] == .en)
            if touches { for j in i ... end { types[j] = .en } }
            i = end + 1
        }
        // W6: the separators and terminators left are neutrals.
        for i in types.indices where types[i] == .es || types[i] == .et || types[i] == .cs { types[i] = .on }
        // W7: a European digit after left-to-right text is left to right.
        lastStrong = embedding
        for i in types.indices {
            if types[i] == .l || types[i] == .r { lastStrong = types[i] }
            if types[i] == .en, lastStrong == .l { types[i] = .l }
        }
        // N1, N2: neutrals take the direction both sides share (numbers
        // counting as right to left), else the line's.
        func direction(_ type: BidiClass) -> BidiClass? {
            switch type {
            case .l: return .l
            case .r, .en, .an: return .r
            default: return nil
            }
        }
        i = 0
        while i < types.count {
            guard isNeutral(types[i]) else { i += 1; continue }
            var end = i
            while end + 1 < types.count, isNeutral(types[end + 1]) { end += 1 }
            let before = i > 0 ? direction(types[i - 1]) ?? embedding : embedding
            let after = end + 1 < types.count ? direction(types[end + 1]) ?? embedding : embedding
            let resolved = before == after ? before : embedding
            for j in i ... end { types[j] = resolved }
            i = end + 1
        }
        // I1, I2.
        var levels = [UInt8](repeating: base, count: count)
        for (position, index) in kept.enumerated() {
            let type = types[position]
            if base % 2 == 0 {
                levels[index] = type == .r ? base + 1 : type == .an || type == .en ? base + 2 : base
            } else {
                levels[index] = type == .l || type == .en || type == .an ? base + 1 : base
            }
        }
        // A dropped character takes the level before it (the line's first).
        var previous = base
        for index in 0 ..< count {
            if isRemoved(classes[index]) { levels[index] = previous } else { previous = levels[index] }
        }
        // L1: separators, and the whitespace before them and at the line's
        // end, at the line's level.
        var trailing = true
        for index in stride(from: count - 1, through: 0, by: -1) {
            let type = classes[index]
            if type == .s || type == .b {
                levels[index] = base
                trailing = true
            } else if trailing, type == .ws || isRemoved(type) {
                levels[index] = base
            } else {
                trailing = false
            }
        }
        return levels
    }
}
#endif
