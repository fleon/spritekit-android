#if canImport(SpriteKit) && os(macOS)
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// The shim's labels against Apple's own `SKLabelNode`, on the same font
/// files: the frame the game sizes its pills, buttons and wells by must come
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

    static let texts = ["W1 / L1", "W10 / L26", "Español (México)", "Français", "Bahasa Indonesia", "Level Select",
                        "Play", "Collection", "Level Designer", "All home!", "0 of 30 cleared", "gpqy", "(", "ñ", "Switchlings"]

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
}
#endif
