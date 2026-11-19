#if SPRITEKIT_SHIM
import Foundation

/// Justified Arabic as Apple's text system justifies it (measured with
/// UIKit's string drawing on Catalyst, macOS 27.2): a line with somewhere
/// to put a kashida (tatweel, U+0640) is widened by kashida alone, its
/// spaces left as they are; one without widens its spaces.
///
/// - A kashida goes after each letter drawn in its initial form: one that
///   joins the letter after it but not the one before (`opportunities`).
///   None goes into a ligature (lam-alef, the lam-lam-heh of الله).
/// - Each place takes the same number of kashida, as few as fill the
///   line at the face's tatweel advance or under, and each is drawn that
///   much narrower so they fill it exactly (`Plan`).
///
/// Apple's own Arabic faces carry an AAT `just` table naming a kashida
/// glyph of their own; a face without one (Android's Noto Naskh Arabic)
/// gets its tatweel, as here. Spread over the same places, the words end up
/// as wide either way.
///
/// On a line mixing Latin runs with Arabic, UIKit's string drawing widens
/// the Latin runs' spaces a little as well (some 2 points each, measured),
/// where TextKit and `CTLineCreateJustifiedLine` give it all to kashida, as
/// this does. (Core Text's framesetter alone widens spaces, and uses kashida
/// only with a face whose table asks for them.)
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

    /// A line's kashida: how many go in each place and how wide each is.
    struct Plan: Equatable {
        /// Kashida in each place.
        var count: Int
        /// Each one's width.
        var width: CGFloat
        /// What each place adds to the line.
        var extra: CGFloat { width * CGFloat(count) }

        /// `slack` spread over `places`, at most `tatweel` a kashida: nil
        /// when there's nothing to fill or nowhere to put it.
        init?(slack: CGFloat, places: Int, tatweel: CGFloat) {
            guard slack > 0, places > 0, tatweel > 0 else { return nil }
            count = Int((slack / (CGFloat(places) * tatweel)).rounded(.up))
            width = slack / CGFloat(places * count)
        }
    }
}
#endif
