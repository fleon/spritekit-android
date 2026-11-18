#if canImport(SpriteKit) && os(macOS)
import AppKit
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// Attributed labels in more than one style and on more than one line,
/// against Apple's `SKLabelNode`: each line takes the largest of its styles'
/// metrics, as SpriteKit sizes the block.
@Suite("Attributed labels in several styles on several lines as SpriteKit lays them out", .serialized)
@MainActor
struct AttributedParagraphParityTests {
    private struct Font: LabelFont {
        var fontName: String
        var pointSize: CGFloat
    }

    static let registered: Bool = {
        for file in ["KoHo-Bold", "Montserrat"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: Fonts.directory + "/" + file + ".ttf") as CFURL, .process, nil)
        }
        return true
    }()

    @Test("Frames match SpriteKit's in every alignment")
    func framesMatch() throws {
        _ = Self.registered
        _ = Fonts.engine
        // Montserrat Black, whose advances are Core Text's to the
        // thousandth: a lighter instance's can tip a line's rounded width.
        let small = ("Montserrat-Black", CGFloat(20)), big = ("Montserrat-Black", CGFloat(30)), thai = ("KoHo-Bold", CGFloat(20))
        let cases: [[(String, (String, CGFloat))]] = [
            [("Hx\n", small), ("Hx", big)],
            [("Hx\n", big), ("Hx", small)],
            [("Hx\nH", small), ("x", big)],
            [("Hx\n", small), ("Hx\n", big), ("Hx", small)],
            [("Hx", small), ("Hx", thai)],
            [("Hx\n", small), ("Hx", thai)],
            [("Level ", small), ("12\nnext", big)],
            [("Hx\n", small), ("Hx\n", big)],
        ]
        var checked = 0, matched = 0
        for pieces in cases {
            let appleText = NSMutableAttributedString(), ourText = NSMutableAttributedString()
            for (text, (name, size)) in pieces {
                appleText.append(NSAttributedString(string: text, attributes: [.font: try #require(NSFont(name: name, size: size))]))
                ourText.append(NSAttributedString(string: text, attributes: [NSAttributedString.Key("NSFont"): Font(fontName: name, pointSize: size)]))
            }
            for h in 0...2 {
                for v in 0...3 {
                    let apple = SpriteKit.SKLabelNode()
                    apple.numberOfLines = 0
                    apple.attributedText = appleText
                    apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
                    apple.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!
                    let ours = SpriteKitShim.SKLabelNode()
                    ours.numberOfLines = 0
                    ours.attributedText = ourText
                    ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
                    ours.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
                    checked += 1
                    if apple.frame == ours.contentFrame { matched += 1 } else {
                        print("'\(appleText.string.debugDescription)' h\(h) v\(v): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
                    }
                }
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    @Test("Each piece is drawn in its own run's style")
    func piecesKeepTheirRuns() throws {
        _ = Fonts.engine
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Hx\nH", attributes: [NSAttributedString.Key("NSFont"): Font(fontName: "Montserrat-SemiBold", pointSize: 20)]))
        text.append(NSAttributedString(string: "x", attributes: [NSAttributedString.Key("NSFont"): Font(fontName: "Montserrat-SemiBold", pointSize: 30)]))
        let node = SpriteKitShim.SKLabelNode()
        node.numberOfLines = 0
        node.attributedText = text
        let layout = try #require(node.layout)
        let runs = try #require(node.laidOutRuns)
        #expect(layout.lines.map(\.line.text) == ["Hx", "H", "x"])
        #expect(runs.map(\.text) == ["Hx", "H", "x"])
        #expect(runs.map(\.fontSize) == [20, 20, 30])
        // The second line's two pieces share a baseline, the larger run after the smaller.
        #expect(layout.lines[1].origin.y == layout.lines[2].origin.y)
        #expect(layout.lines[2].origin.x > layout.lines[1].origin.x)
    }
}
#endif
