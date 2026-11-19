#if SPRITEKIT_SHIM
import Foundation

/// A justified line without kashida as Apple's text system justifies it
/// (measured with UIKit's string drawing on Catalyst, macOS 27.2, which
/// justifies a line as `CTLineCreateJustifiedLine` does, for a face without
/// an AAT `just` table): its spaces widen first, then its letters too.
///
/// Every gap after a character but the line's last widens: after a space,
/// or between two letters (anything but a space). The gap before a space
/// never does.
/// - Spaces take the slack first, each by its em, up to half an em more.
/// - Then letters and spaces share the rest: a gap between letters by the
///   mean of their ems, a space by half the em of the letter after it; a
///   letter gap up to 37/128 of its em more.
/// - Then the spaces take the rest, each by its em.
///
/// A line without spaces gives its letters everything, as far as it takes;
/// one without letter gaps gives its spaces everything. A squeezed line
/// (negative slack) tightens its spaces only, equally.
enum Justification {
    /// A gap after a character.
    enum Gap: Equatable {
        /// After a space of this em, before a letter of `nextEm` (0 for none).
        case space(em: CGFloat, nextEm: CGFloat)
        /// Between two letters, the mean of their ems.
        case letter(em: CGFloat)
        /// Before a space, or after the line's last character.
        case none
    }

    /// A space's most in the first stage, in ems.
    static let spaceLimit: CGFloat = 0.5
    /// A letter gap's most before the spaces take the rest, in ems.
    static let letterLimit: CGFloat = 37 / 128

    /// The gaps after each of `characters`, each character's em in `ems`.
    static func gaps(_ characters: [Character], ems: [CGFloat]) -> [Gap] {
        characters.indices.map { index in
            guard index + 1 < characters.count else { return .none }
            let next = characters[index + 1]
            if characters[index] == " " {
                return .space(em: ems[index], nextEm: next == " " ? 0 : ems[index + 1])
            }
            return next == " " ? .none : .letter(em: (ems[index] + ems[index + 1]) / 2)
        }
    }

    /// What `slack` adds to each gap.
    static func extras(slack: CGFloat, gaps: [Gap]) -> [CGFloat] {
        var spaceEms: CGFloat = 0, spaceCount = 0, letterEms: CGFloat = 0, sharedEms: CGFloat = 0
        for gap in gaps {
            switch gap {
            case let .space(em, nextEm): spaceEms += em; spaceCount += 1; sharedEms += nextEm / 2
            case let .letter(em): letterEms += em; sharedEms += em
            case .none: break
            }
        }
        guard slack != 0, spaceCount > 0 || letterEms > 0 else { return gaps.map { _ in 0 } }
        if slack < 0 {
            return gaps.map { if case .space = $0 { slack / CGFloat(spaceCount) } else { 0 } }
        }
        // No letters to widen: the spaces take it all, each by its em.
        guard letterEms > 0 else {
            return gaps.map { if case let .space(em, _) = $0 { slack * em / spaceEms } else { 0 } }
        }
        // No spaces: the letters do, without a limit.
        guard spaceCount > 0 else {
            return gaps.map { if case let .letter(em) = $0 { slack * em / letterEms } else { 0 } }
        }
        let firstStage = spaceEms * Self.spaceLimit
        if slack <= firstStage {
            return gaps.map { if case let .space(em, _) = $0 { slack * em / spaceEms } else { 0 } }
        }
        let rest = slack - firstStage
        let share = min(rest / sharedEms, Self.letterLimit)
        let left = rest - share * sharedEms
        return gaps.map { gap in
            switch gap {
            case let .space(em, nextEm): em * Self.spaceLimit + nextEm / 2 * share + left * em / spaceEms
            case let .letter(em): em * share
            case .none: 0
            }
        }
    }
}
#endif
