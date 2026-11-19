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
/// to U+2069) set levels as X1 to X8 set them; embeddings and overrides are
/// then dropped from what the rules see (X9), and each isolating run
/// sequence is resolved on its own (X10).
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
        // What an isolate holds doesn't count (P2).
        var depth = 0
        for scalar in text.unicodeScalars {
            switch bidiClass(scalar) {
            case .l where depth == 0: return .leftToRight
            case .r where depth == 0, .al where depth == 0: return .rightToLeft
            case .lri, .rli, .fsi: depth += 1
            case .pdi: if depth == 0 { return nil } else { depth -= 1 }
            case .b: return nil
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
        let base: UInt8 = firstStrong(classes, in: 0 ..< classes.count).map { $0 == .l ? 0 : 1 } ?? 0
        return (resolve(classes, base: base), base)
    }

    /// Each scalar's level for `scalars` as one line of a paragraph in
    /// `direction`.
    public static func levels(_ scalars: [Unicode.Scalar], in direction: Direction) -> [UInt8] {
        resolve(scalars.map(bidiClass), base: direction.level)
    }

    /// Whether `scalar` is an explicit embedding, override or isolate, or
    /// what ends one.
    public static func isExplicitControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A ... 0x202E).contains(scalar.value) || (0x2066 ... 0x2069).contains(scalar.value)
    }

    /// `text` forced to read in one direction: its explicit controls taken
    /// out and the rest wrapped in an override of that direction, led by
    /// that direction's mark (an override doesn't set the paragraph's, so
    /// spaces it ends on would otherwise go to the other end), so laid out
    /// alone it comes out as the line it was cut from had it.
    public static func overridden(_ text: String, rightToLeft: Bool) -> String {
        let body = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isExplicitControl($0) }))
        return (rightToLeft ? "\u{200F}\u{202E}" : "\u{200E}\u{202D}") + body + "\u{202C}"
    }

    /// A stretch of one piece of a line at one level.
    public struct Segment: Equatable, Sendable {
        /// Which piece, and which of its characters (offsets into it).
        public var piece: Int
        public var characters: Range<Int>
        public var level: UInt8
        /// Whether, led by its mark and laid out alone, some of it would
        /// read the other way: an override, embedding or isolate opened in an
        /// earlier piece sets its level, as Core Text carries one across
        /// attribute runs. Drawn `overridden` to its direction.
        public var overridden = false
        /// Whether it reads right to left (an odd level).
        public var rightToLeft: Bool { level % 2 == 1 }
    }

    /// A line made of `pieces` (stretches of text in their own styles, in
    /// logical order) as one line of a paragraph in `direction`: the
    /// stretches of one piece and one level each, in the order drawn, left
    /// to right (L2 across the pieces). Each is drawn in its own direction,
    /// led by its mark (`marked`).
    public static func segments(of pieces: [String], in direction: Direction) -> [Segment] {
        var scalars: [Unicode.Scalar] = []
        // Each character's piece, offset and first scalar.
        var characters: [(piece: Int, offset: Int, scalar: Int)] = []
        for (number, piece) in pieces.enumerated() {
            for (offset, character) in piece.enumerated() {
                characters.append((number, offset, scalars.count))
                scalars.append(contentsOf: character.unicodeScalars)
            }
        }
        let levels = levels(scalars, in: direction)
        var segments: [Segment] = []
        for character in characters {
            let level = levels[character.scalar]
            if let last = segments.last, last.piece == character.piece, last.level == level {
                segments[segments.count - 1].characters = last.characters.lowerBound ..< character.offset + 1
            } else {
                segments.append(Segment(piece: character.piece, characters: character.offset ..< character.offset + 1, level: level))
            }
        }
        // Only explicit controls set a level the stretch's own characters
        // wouldn't give it alone.
        if scalars.contains(where: isExplicitControl) {
            for index in segments.indices {
                let segment = segments[index]
                let text = String(Array(pieces[segment.piece])[segment.characters])
                let own = Self.levels(Array(marked(text, in: segment.rightToLeft ? .rightToLeft : .leftToRight).unicodeScalars)).levels
                // The mark, if any, comes first; controls, and what X9
                // removes, read no way.
                segments[index].overridden = zip(own.suffix(text.unicodeScalars.count), text.unicodeScalars).contains { level, scalar in
                    !isExplicitControl(scalar) && !isRemoved(bidiClass(scalar)) && level % 2 != segment.level % 2
                }
            }
        }
        return visualOrder(segments.map(\.level)).map { segments[$0] }
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

    /// Dropped before the rules run (X9): embeddings, overrides, their
    /// ends, and boundary neutrals. Isolates stay, as neutrals.
    static func isRemoved(_ type: BidiClass) -> Bool {
        switch type {
        case .bn, .lre, .lro, .rle, .rlo, .pdf: return true
        default: return false
        }
    }

    private static func isIsolateInitiator(_ type: BidiClass) -> Bool { type == .lri || type == .rli || type == .fsi }

    private static func isNeutral(_ type: BidiClass) -> Bool {
        switch type {
        case .b, .s, .ws, .on, .lri, .rli, .fsi, .pdi: return true
        default: return false
        }
    }

    /// The first strong type in `classes[range]` (P2), skipping what an
    /// isolate holds and stopping at an unmatched isolate end.
    static func firstStrong(_ classes: [BidiClass], in range: Range<Int>) -> BidiClass? {
        var depth = 0
        for index in range {
            switch classes[index] {
            case .lri, .rli, .fsi: depth += 1
            case .pdi:
                if depth == 0 { return nil }
                depth -= 1
            case .l, .r, .al:
                if depth == 0 { return classes[index] }
            case .b: return nil
            default: continue
            }
        }
        return nil
    }

    /// The whole algorithm over one line at paragraph level `base`: the
    /// explicit levels (X1 to X8), what the rules see (X9), each isolating
    /// run sequence resolved on its own (X10, W1 to I2), then L1.
    static func resolve(_ classes: [BidiClass], base: UInt8) -> [UInt8] {
        let count = classes.count
        guard count > 0 else { return [] }
        var types = classes
        var levels = [UInt8](repeating: base, count: count)

        // BD9: each isolate initiator's matching end, and back.
        var matchingEnd = [Int](repeating: -1, count: count)
        var matchingStart = [Int](repeating: -1, count: count)
        var open: [Int] = []
        for index in 0 ..< count {
            switch classes[index] {
            case .lri, .rli, .fsi: open.append(index)
            case .pdi:
                if let start = open.popLast() {
                    matchingEnd[start] = index
                    matchingStart[index] = start
                }
            case .b: open.removeAll()
            default: break
            }
        }

        // X1 to X8: the directional status stack.
        struct Status { var level: UInt8; var override: BidiClass?; var isolate: Bool }
        var stack = [Status(level: base, override: nil, isolate: false)]
        var overflowIsolates = 0, overflowEmbeddings = 0, validIsolates = 0
        let maxDepth: UInt8 = 125
        func next(rightToLeft: Bool, after level: UInt8) -> UInt8 {
            rightToLeft ? (level + 1) | 1 : (level + 2) & ~1
        }
        for index in 0 ..< count {
            let top = stack[stack.count - 1]
            switch classes[index] {
            case .rle, .lre, .rlo, .lro:
                let type = classes[index]
                levels[index] = top.level
                let level = next(rightToLeft: type == .rle || type == .rlo, after: top.level)
                if level <= maxDepth, overflowIsolates == 0, overflowEmbeddings == 0 {
                    stack.append(Status(level: level, override: type == .rlo ? .r : type == .lro ? .l : nil, isolate: false))
                } else if overflowIsolates == 0 {
                    overflowEmbeddings += 1
                }
            case .rli, .lri, .fsi:
                levels[index] = top.level
                if let override = top.override { types[index] = override }
                var rightToLeft = classes[index] == .rli
                if classes[index] == .fsi {
                    let end = matchingEnd[index] >= 0 ? matchingEnd[index] : count
                    let strong = firstStrong(classes, in: index + 1 ..< end)
                    rightToLeft = strong == .r || strong == .al
                }
                let level = next(rightToLeft: rightToLeft, after: top.level)
                if level <= maxDepth, overflowIsolates == 0, overflowEmbeddings == 0 {
                    validIsolates += 1
                    stack.append(Status(level: level, override: nil, isolate: true))
                } else {
                    overflowIsolates += 1
                }
            case .pdi:
                if overflowIsolates > 0 {
                    overflowIsolates -= 1
                } else if validIsolates > 0 {
                    overflowEmbeddings = 0
                    while let last = stack.last, !last.isolate { stack.removeLast() }
                    stack.removeLast()
                    validIsolates -= 1
                }
                let now = stack[stack.count - 1]
                levels[index] = now.level
                if let override = now.override { types[index] = override }
            case .pdf:
                levels[index] = top.level
                if overflowIsolates > 0 {
                } else if overflowEmbeddings > 0 {
                    overflowEmbeddings -= 1
                } else if !top.isolate, stack.count >= 2 {
                    stack.removeLast()
                }
            case .b:
                levels[index] = base
            case .bn:
                levels[index] = top.level
            default:
                levels[index] = top.level
                if let override = top.override { types[index] = override }
            }
        }

        // X9, X10: level runs of what the rules see, joined across isolates
        // into isolating run sequences.
        let kept = (0 ..< count).filter { !isRemoved(classes[$0]) }
        guard !kept.isEmpty else { return levels }
        var runs: [[Int]] = []
        for index in kept {
            if let last = runs.last?.last, levels[last] == levels[index] {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        var runStartingAt: [Int: Int] = [:]
        for (number, run) in runs.enumerated() { runStartingAt[run[0]] = number }
        var sequences: [[Int]] = []
        for run in runs {
            // A run starting with a matched isolate end continues a sequence.
            if classes[run[0]] == .pdi, matchingStart[run[0]] >= 0 { continue }
            var sequence = run
            while let last = sequence.last, isIsolateInitiator(classes[last]), matchingEnd[last] >= 0,
                  let following = runStartingAt[matchingEnd[last]] {
                sequence += runs[following]
            }
            sequences.append(sequence)
        }
        let keptPosition = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        for sequence in sequences {
            let level = levels[sequence[0]]
            let first = keptPosition[sequence[0]]!, last = keptPosition[sequence[sequence.count - 1]]!
            let before = first > 0 ? levels[kept[first - 1]] : base
            let lastIsInitiator = isIsolateInitiator(classes[sequence[sequence.count - 1]])
            let after = !lastIsInitiator && last + 1 < kept.count ? levels[kept[last + 1]] : base
            let sos: BidiClass = max(level, before) % 2 == 0 ? .l : .r
            let eos: BidiClass = max(level, after) % 2 == 0 ? .l : .r
            var sequenceTypes = sequence.map { types[$0] }
            resolveWeakAndNeutral(&sequenceTypes, classes: sequence.map { classes[$0] }, sos: sos, eos: eos, level: level)
            for (position, index) in sequence.enumerated() {
                let type = sequenceTypes[position]
                if level % 2 == 0 {
                    levels[index] = type == .r ? level + 1 : type == .an || type == .en ? level + 2 : level
                } else {
                    levels[index] = type == .l || type == .en || type == .an ? level + 1 : level
                }
            }
        }

        // A dropped character takes the level before it (the line's first).
        var previous = base
        for index in 0 ..< count {
            if isRemoved(classes[index]) { levels[index] = previous } else { previous = levels[index] }
        }
        // L1: separators, and the whitespace and isolate controls before them
        // and at the line's end, at the line's level.
        var trailing = true
        for index in stride(from: count - 1, through: 0, by: -1) {
            let type = classes[index]
            if type == .s || type == .b {
                levels[index] = base
                trailing = true
            } else if trailing, type == .ws || isRemoved(type) || isIsolateInitiator(type) || type == .pdi {
                levels[index] = base
            } else {
                trailing = false
            }
        }
        return levels
    }

    /// W1 to N2 over one isolating run sequence's types.
    private static func resolveWeakAndNeutral(_ types: inout [BidiClass], classes: [BidiClass], sos: BidiClass, eos: BidiClass, level: UInt8) {
        let count = types.count
        let embedding: BidiClass = level % 2 == 0 ? .l : .r
        // W1: a mark takes the type before it (sos at the start, a neutral
        // after an isolate's start or end).
        for i in 0 ..< count where types[i] == .nsm {
            if i == 0 {
                types[i] = sos
            } else {
                let before = types[i - 1]
                types[i] = isIsolateInitiator(before) || before == .pdi ? .on : before
            }
        }
        // W2: a European digit after Arabic letters is an Arabic one.
        var lastStrong = sos
        for i in 0 ..< count {
            if isStrong(types[i]) { lastStrong = types[i] }
            if types[i] == .en, lastStrong == .al { types[i] = .an }
        }
        // W3: Arabic letters are right to left.
        for i in 0 ..< count where types[i] == .al { types[i] = .r }
        // W4: one separator between two numbers of a kind joins them.
        if count >= 3 {
            for i in 1 ..< count - 1 {
                let before = types[i - 1], after = types[i + 1]
                if types[i] == .es, before == .en, after == .en { types[i] = .en }
                if types[i] == .cs, before == after, before == .en || before == .an { types[i] = before }
            }
        }
        // W5: terminators next to a European digit become digits.
        var i = 0
        while i < count {
            guard types[i] == .et else { i += 1; continue }
            var end = i
            while end + 1 < count, types[end + 1] == .et { end += 1 }
            let touches = (i > 0 && types[i - 1] == .en) || (end + 1 < count && types[end + 1] == .en)
            if touches { for j in i ... end { types[j] = .en } }
            i = end + 1
        }
        // W6: the separators and terminators left are neutrals.
        for i in 0 ..< count where types[i] == .es || types[i] == .et || types[i] == .cs { types[i] = .on }
        // W7: a European digit after left-to-right text is left to right.
        lastStrong = sos
        for i in 0 ..< count {
            if types[i] == .l || types[i] == .r { lastStrong = types[i] }
            if types[i] == .en, lastStrong == .l { types[i] = .l }
        }
        // N1, N2: neutrals take the direction both sides share (numbers
        // counting as right to left), else the embedding's.
        func direction(_ type: BidiClass) -> BidiClass? {
            switch type {
            case .l: return .l
            case .r, .en, .an: return .r
            default: return nil
            }
        }
        i = 0
        while i < count {
            guard isNeutral(types[i]) else { i += 1; continue }
            var end = i
            while end + 1 < count, isNeutral(types[end + 1]) { end += 1 }
            let before = i > 0 ? direction(types[i - 1]) ?? embedding : sos
            let after = end + 1 < count ? direction(types[end + 1]) ?? embedding : eos
            let resolved = before == after ? before : embedding
            for j in i ... end { types[j] = resolved }
            i = end + 1
        }
    }
}
#endif
