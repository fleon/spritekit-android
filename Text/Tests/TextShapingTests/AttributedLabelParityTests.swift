#if canImport(SpriteKit) && os(macOS)
import AppKit
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// An attributed label's letter spacing (`.kern`) against Apple's own
/// `SKLabelNode`, on the same font file: the frame comes out the same in
/// every horizontal alignment.
@Suite("Attributed labels as SpriteKit lays them out", .serialized)
@MainActor
struct AttributedLabelParityTests {
    private struct Font: LabelFont {
        var fontName: String
        var pointSize: CGFloat
    }

    static let geneva = "/System/Library/Fonts/Geneva.ttf"

    static let engine: TextEngine = {
        let library = FontLibrary()
        let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        _ = try? library.register(path: geneva)
        engine.install()
        return engine
    }()

    @Test("Kerned frames match SpriteKit's", arguments: [-0.5, 1.2, 3] as [CGFloat])
    func kerned(kern: CGFloat) throws {
        _ = Self.engine
        let size: CGFloat = 20
        let nsFont = try #require(NSFont(name: "Geneva", size: size))
        var checked = 0, matched = 0
        for text in ["Select a level", "12 of 300 completed", "W", "Play"] {
            for h in 0...2 {
                let apple = SpriteKit.SKLabelNode()
                apple.attributedText = NSAttributedString(string: text, attributes: [.font: nsFont, .kern: NSNumber(value: Float(kern))])
                apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
                apple.verticalAlignmentMode = .center

                let ours = SpriteKitShim.SKLabelNode()
                ours.attributedText = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key("NSFont"): Font(fontName: "Geneva", pointSize: size),
                    NSAttributedString.Key("NSKern"): NSNumber(value: Float(kern)),
                ])
                ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
                ours.verticalAlignmentMode = .center
                checked += 1
                if apple.frame == ours.contentFrame { matched += 1 } else {
                    print("kern \(kern) '\(text)' h\(h): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
                }
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    @Test("A string's width with letter spacing is AppKit's: the spacing after every character, the last included", arguments: [0, 1.5, 3] as [CGFloat])
    func width(kern: CGFloat) throws {
        _ = Self.engine
        let nsFont = try #require(NSFont(name: "Geneva", size: 20))
        for text in ["Play", "W", "Select a level", "Continue"] {
            let apple = NSAttributedString(string: text, attributes: [.font: nsFont, .kern: NSNumber(value: Double(kern))]).size().width
            let ours = StringDrawing.width(of: text, font: FontKey(name: "Geneva", size: 20), kern: kern)
            #expect(abs(apple - ours) < 0.01, "'\(text)' kern \(kern): AppKit \(apple), ours \(ours)")
        }
    }

    @Test("The font, colour and spacing come from the attributes, and clearing them keeps the text")
    func adopted() {
        let ours = SpriteKitShim.SKLabelNode(fontNamed: "Other")
        ours.attributedText = NSAttributedString(string: "Hi", attributes: [
            NSAttributedString.Key("NSFont"): Font(fontName: "Geneva", pointSize: 17),
            NSAttributedString.Key("NSColor"): SpriteKitShim.SKColor.red,
            NSAttributedString.Key("NSKern"): NSNumber(value: 2),
        ])
        #expect(ours.text == "Hi")
        #expect(ours.fontName == "Geneva")
        #expect(ours.fontSize == 17)
        #expect(ours.fontColor == .red)
        #expect(ours.kern == 2)
        ours.attributedText = nil
        #expect(ours.kern == 0)
        #expect(ours.text == "Hi")
    }
}
#endif
