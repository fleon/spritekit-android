#if SPRITEKIT_SHIM
import Foundation

/// Justified Arabic as Apple's text system justifies it (measured with
/// UIKit's string drawing on Catalyst, macOS 27.2, which justifies a line
/// as `CTLineCreateJustifiedLine` does): kashida (tatweel, U+0640) widen it
/// where they can, and spaces beside Latin only once they can't.
///
/// - A kashida goes after a letter that joins the letter after it, unless
///   the two are drawn as one ligature (lam-alef, the lam-lam-heh of الله):
///   after a letter in its initial form (`opportunities`), or in its medial
///   form (`medials`).
/// - A line with no medial place gives everything to its initial places, in
///   equal shares, its spaces as they are.
/// - Otherwise its initial places fill first, to 0.8 em each (`Shares`);
///   then its medial places and its spaces share the rest, each by its em,
///   a space up to half an em more; then the medial places take the rest.
///   Only spaces left of the line's first stretch with a place widen, and
///   of those not one between two Arabic letters (nor a line's last).
/// - Each place takes as few kashida as fill it at the face's tatweel
///   advance or under, each drawn that much narrower so they fill it
///   exactly (`glyphs`).
///
/// Apple's own Arabic faces carry an AAT `just` table that says otherwise
/// (a kashida glyph of their own, its own limits); a face without one
/// (Android's Noto Naskh Arabic) is justified as here. (Core Text's
/// framesetter alone widens spaces, and uses kashida only with a face whose
/// table asks for them.)
enum Kashida {
    /// How a character joins its neighbours (Unicode's Joining_Type).
    enum Joining: Sendable {
        case dual, right, left, causing
    }

    static func joining(_ scalar: Unicode.Scalar) -> Joining? {
        var low = 0, high = joiningRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = joiningRanges[middle]
            if scalar.value < range.0 {
                high = middle - 1
            } else if scalar.value > range.1 {
                low = middle + 1
            } else {
                return range.2
            }
        }
        return nil
    }

    /// Whether `character` joins the one after it: a dual- or left-joining
    /// letter, a tatweel, or anything a zero-width joiner follows, unless a
    /// zero-width non-joiner does.
    static func joinsNext(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        if scalars.contains("\u{200C}") { return false }
        if scalars.dropFirst().contains("\u{200D}") { return true }
        guard let base = scalars.first, let joining = joining(base) else { return false }
        return joining != .right
    }

    /// Whether `character` joins the one before it.
    static func joinsPrevious(_ character: Character) -> Bool {
        guard let base = character.unicodeScalars.first, let joining = joining(base) else { return false }
        return joining != .left
    }

    /// The indices of the characters a kashida may follow: each letter that
    /// joins the next but not the previous, unless the next is drawn in a
    /// ligature with it (it has no advance of its own in `advances`, each
    /// character's as shaped in the line).
    static func opportunities(in characters: [Character], advances: [CGFloat]) -> [Int] {
        guard characters.count > 1, advances.count == characters.count else { return [] }
        var found: [Int] = []
        for index in 0 ..< characters.count - 1 {
            let character = characters[index]
            guard let base = character.unicodeScalars.first, let joining = joining(base),
                  joining == .dual || joining == .left,
                  joinsNext(character), joinsPrevious(characters[index + 1]), advances[index + 1] > 0 else { continue }
            if index > 0, joinsNext(characters[index - 1]), joinsPrevious(character) { continue }
            found.append(index)
        }
        return found
    }

    /// The indices of the characters drawn in their medial form a kashida
    /// may follow: each letter joined to the one before it and to the next,
    /// unless the next is drawn in a ligature with it (it has no advance of
    /// its own in `advances`), or it is itself in one with the one before.
    static func medials(in characters: [Character], advances: [CGFloat]) -> [Int] {
        guard characters.count > 2, advances.count == characters.count else { return [] }
        var found: [Int] = []
        for index in 1 ..< characters.count - 1 {
            let character = characters[index]
            guard let base = character.unicodeScalars.first, joining(base) == .dual, advances[index] > 0,
                  joinsNext(characters[index - 1]), joinsPrevious(character),
                  joinsNext(character), joinsPrevious(characters[index + 1]), advances[index + 1] > 0 else { continue }
            found.append(index)
        }
        return found
    }

    /// What a justified line's slack adds to each initial place, each
    /// medial place and each space that can widen, given each one's em.
    struct Shares: Equatable {
        var initials: [CGFloat]
        var medials: [CGFloat]
        var spaces: [CGFloat]

        /// An initial place's most before the rest share, in ems.
        static let initialLimit: CGFloat = 0.8
        /// A space's most, in ems.
        static let spaceLimit: CGFloat = 0.5

        init(slack: CGFloat, initials: [CGFloat], medials: [CGFloat], spaces: [CGFloat]) {
            let initialEms = initials.reduce(0, +)
            guard slack > 0, initialEms > 0 || !medials.isEmpty else {
                self.initials = initials.map { _ in 0 }
                self.medials = medials.map { _ in 0 }
                self.spaces = spaces.map { _ in 0 }
                return
            }
            let cap = initialEms * Self.initialLimit
            // Nowhere else at the kashida's turn: the initial places take it all.
            if medials.isEmpty || slack <= cap {
                self.initials = initials.map { slack * $0 / initialEms }
                self.medials = medials.map { _ in 0 }
                self.spaces = spaces.map { _ in 0 }
                return
            }
            self.initials = initials.map { $0 * Self.initialLimit }
            let rest = slack - cap
            let medialEms = medials.reduce(0, +), spaceEms = spaces.reduce(0, +)
            // Each takes the same share of its em, a space up to its limit.
            let share = rest / (medialEms + spaceEms)
            if share <= Self.spaceLimit {
                self.medials = medials.map { $0 * share }
                self.spaces = spaces.map { $0 * share }
            } else {
                self.spaces = spaces.map { $0 * Self.spaceLimit }
                let left = rest - spaceEms * Self.spaceLimit
                self.medials = medials.map { left * $0 / medialEms }
            }
        }
    }

    /// The kashida that fill `extra`: as few as do at `tatweel` each or
    /// under, each that much narrower.
    static func glyphs(filling extra: CGFloat, tatweel: CGFloat) -> (count: Int, width: CGFloat) {
        guard extra > 0, tatweel > 0 else { return (0, 0) }
        let count = Int((extra / tatweel).rounded(.up))
        return (count, extra / CGFloat(count))
    }
}
#endif
