import Foundation
import Testing
@testable import SpriteKitShim

/// A justified left-to-right line's slack shared as Core Text shares it
/// (`Justification`; the numbers `CTLineCreateJustifiedLine` gave on a Mac,
/// macOS 27.2, Montserrat Black).
@Suite("Justified lines' shares")
struct JustificationTests {
    @Test("The shares Core Text gives, mixed sizes included")
    func shares() {
        // Montserrat-Black 15, "Hello world": the space to half an em, then
        // letters and the space by 1 to 1/2, the letters to 37/128 em.
        let ems = [CGFloat](repeating: 15, count: 11)
        let gaps = Justification.gaps(Array("Hello world"), ems: ems)
        func rounded(_ values: [CGFloat]) -> [Double] { values.map { (Double($0) * 100).rounded() / 100 } }
        #expect(rounded(Justification.extras(slack: 4, gaps: gaps)) == [0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0])
        #expect(rounded(Justification.extras(slack: 12, gaps: gaps)) == [0.53, 0.53, 0.53, 0.53, 0, 7.76, 0.53, 0.53, 0.53, 0.53, 0])
        #expect(rounded(Justification.extras(slack: 60, gaps: gaps)) == [4.34, 4.34, 4.34, 4.34, 0, 25.31, 4.34, 4.34, 4.34, 4.34, 0])
        // No spaces: the letters take it all; no letter gaps: the spaces do.
        #expect(rounded(Justification.extras(slack: 60, gaps: Justification.gaps(Array("Hello"), ems: [15, 15, 15, 15, 15]))) == [15, 15, 15, 15, 0])
        #expect(rounded(Justification.extras(slack: 60, gaps: Justification.gaps(Array("a b"), ems: [15, 15, 15]))) == [0, 60, 0])
        // "ab " at 10, "cd " at 20, "ef" at 10 (Core Text's numbers).
        let mixed = Justification.gaps(Array("ab cd ef"), ems: [10, 10, 10, 20, 20, 20, 10, 10])
        #expect(rounded(Justification.extras(slack: 4, gaps: mixed)) == [0, 0, 1.33, 0, 0, 2.67, 0, 0])
        #expect(rounded(Justification.extras(slack: 16, gaps: mixed)) == [0.18, 0, 5.18, 0.36, 0, 10.09, 0.18, 0])
        #expect(rounded(Justification.extras(slack: 40, gaps: mixed)) == [2.89, 0, 10.92, 5.78, 0, 17.51, 2.89, 0])
        // "abc" at 10, "def" at 20, no spaces: the gap between them by the mean.
        let sizes = Justification.gaps(Array("abcdef"), ems: [10, 10, 10, 20, 20, 20])
        #expect(rounded(Justification.extras(slack: 4, gaps: sizes)) == [0.53, 0.53, 0.8, 1.07, 1.07, 0])
    }
}
