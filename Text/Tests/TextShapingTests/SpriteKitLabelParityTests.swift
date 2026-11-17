#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// The shim's labels against Apple's own `SKLabelNode`, on the same font
/// files: the frame a game sizes its pills, buttons and wells by must come
/// out the same, point for point.
@Suite("Labels as SpriteKit lays them out")
@MainActor
struct SpriteKitLabelParityTests {
    static let registered: Bool = {
        for file in ["KoHo-Bold", "Montserrat"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: Fonts.directory + "/" + file + ".ttf") as CFURL, .process, nil)
        }
        return true
    }()

    static let texts = ["A1 / B1", "W10 / L26", "Español (México)", "Français", "Bahasa Indonesia", "Level Select",
                        "Play", "Collection", "Level Editor", "All done!", "0 of 30 cleared", "gpqy", "(", "ñ", "Lightning"]

    @Test("Frames match SpriteKit's in every alignment", arguments: ["Montserrat-Black", "Montserrat-ExtraBold", "Montserrat-SemiBold"])
    func framesMatch(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        for size in [13, 15, 20, 28] as [CGFloat] {
            for text in Self.texts {
                for (h, v) in [(0, 0), (1, 1), (2, 2), (0, 3)] {
                    let apple = SpriteKit.SKLabelNode(fontNamed: font)
                    apple.fontSize = size
                    apple.text = text
                    apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
                    apple.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!
                    let ours = SpriteKitShim.SKLabelNode(fontNamed: font)
                    ours.fontSize = size
                    ours.text = text
                    ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
                    ours.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
                    checked += 1
                    if apple.frame == ours.contentFrame { matched += 1 } else {
                        print("\(font) \(size) '\(text)' h\(h) v\(v): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
                    }
                }
            }
        }
        // Core Text keeps a variable instance's advance deltas fractional,
        // where HarfBuzz rounds them to whole font units: a hundredth of a
        // point a glyph, which across a long line can tip its ink over a
        // whole point.
        let share = font == "Montserrat-Black" ? 1.0 : 0.98
        #expect(Double(matched) >= Double(checked) * share, "\(matched) of \(checked) frames match")
    }

    @Test("Multi-line frames match SpriteKit's in every alignment", arguments: ["Montserrat-SemiBold", "Montserrat-Black", "KoHo-Bold", "Geneva"])
    func multiLineFramesMatch(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        for size in [13, 20, 27.5] as [CGFloat] {
            for text in ["Hx", "H\nH", "gpqy\nHELLO", "A\nlonger second line\nB", "Level\nSelect", "All done!\n0 of 30 cleared"] {
                for h in 0...2 {
                    for v in 0...3 {
                        let apple = SpriteKit.SKLabelNode(fontNamed: font)
                        apple.fontSize = size
                        apple.numberOfLines = 0
                        apple.text = text
                        apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
                        apple.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!
                        let ours = SpriteKitShim.SKLabelNode(fontNamed: font)
                        ours.fontSize = size
                        ours.numberOfLines = 0
                        ours.text = text
                        ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
                        ours.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
                        checked += 1
                        if apple.frame == ours.contentFrame { matched += 1 } else {
                            print("\(font) \(size) '\(text)' h\(h) v\(v): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
                        }
                    }
                }
            }
        }
        // As for one line: Core Text's fractional instance advances can tip
        // the widest line over a whole point.
        #expect(Double(matched) >= Double(checked) * 0.98, "\(matched) of \(checked) frames match")
    }

    @Test("Lines are as far apart as SpriteKit's", arguments: ["Montserrat-SemiBold", "Montserrat-Black", "KoHo-Bold"])
    func lineSpacingMatches(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        // A 21-line label's height less a 1-line one's is 20 line advances,
        // whatever SpriteKit pads the block with.
        let many = Array(repeating: "Hx", count: 21).joined(separator: "\n")
        for size in [9, 12, 15.5, 20, 33] as [CGFloat] {
            func apple(_ text: String) -> CGFloat {
                let node = SpriteKit.SKLabelNode(fontNamed: font)
                node.fontSize = size
                node.numberOfLines = 0
                node.text = text
                return node.frame.height
            }
            func ours(_ text: String) -> CGFloat {
                let node = SpriteKitShim.SKLabelNode(fontNamed: font)
                node.fontSize = size
                node.numberOfLines = 0
                node.text = text
                guard let lines = node.layout?.lines, lines.count > 1 else { return 0 }
                return lines[0].origin.y - lines[lines.count - 1].origin.y
            }
            let theirs = (apple(many) - apple("Hx")) / 20
            let mine = ours(many) / 20
            #expect(abs(mine - theirs) < 0.001, "\(font) \(size): \(mine) against SpriteKit's \(theirs)")
        }
    }
}
#endif
