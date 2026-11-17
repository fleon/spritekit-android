#if canImport(SpriteKit) && os(macOS)
import AppKit
import CoreText
import Foundation
import SpriteKit
import SpriteKitShim
import Testing
@testable import TextShaping

/// Attributed labels in more than one style against Apple's own
/// `SKLabelNode`, on the same font file: the runs sit end to end on one
/// baseline, `.baselineOffset` raises its run, and the frame is the whole
/// line's, placed by every alignment mode as a one-style line is.
@Suite("Attributed labels in several styles as SpriteKit lays them out", .serialized)
@MainActor
struct AttributedLabelRunTests {
    private struct Font: LabelFont {
        var fontName: String
        var pointSize: CGFloat
    }

    static let geneva = "/System/Library/Fonts/Geneva.ttf"

    /// The suite's one shared engine (`Fonts.engine`), with Geneva added:
    /// swapping in an engine of its own would change every other test's text.
    static let engine: TextEngine = {
        let engine = Fonts.engine
        _ = try? engine.library.register(path: geneva)
        return engine
    }()

    /// The same runs as Apple's attributes and as the shim's.
    struct Piece {
        var text: String
        var size: CGFloat
        var baselineOffset: CGFloat = 0
    }

    private func apple(_ pieces: [Piece]) throws -> NSAttributedString {
        let text = NSMutableAttributedString()
        for piece in pieces {
            let font = try #require(NSFont(name: "Geneva", size: piece.size))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.red]
            if piece.baselineOffset != 0 { attributes[.baselineOffset] = piece.baselineOffset }
            text.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return text
    }

    private func ours(_ pieces: [Piece]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for piece in pieces {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key("NSFont"): Font(fontName: "Geneva", pointSize: piece.size),
                NSAttributedString.Key("NSColor"): SpriteKitShim.SKColor.red,
            ]
            if piece.baselineOffset != 0 { attributes[NSAttributedString.Key("NSBaselineOffset")] = piece.baselineOffset }
            text.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return text
    }

    static let lines: [[Piece]] = [
        [Piece(text: "12", size: 40), Piece(text: " / 40", size: 20)],
        [Piece(text: "AB", size: 40), Piece(text: "*", size: 20, baselineOffset: 10), Piece(text: "C", size: 40)],
    ]

    @Test("Frames match SpriteKit's in every alignment", arguments: 0 ..< lines.count)
    func frames(line: Int) throws {
        _ = Self.engine
        let pieces = Self.lines[line]
        var checked = 0, matched = 0
        for h in 0 ... 2 {
            for v in 0 ... 3 {
                let reference = SpriteKit.SKLabelNode()
                reference.attributedText = try apple(pieces)
                reference.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
                reference.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!

                let label = SpriteKitShim.SKLabelNode()
                label.attributedText = ours(pieces)
                label.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
                label.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
                checked += 1
                // Within a point: SpriteKit rounds the line's ink out to whole
                // points, and two shapers' ink boxes differ by a fraction.
                let a = reference.frame, b = label.contentFrame
                if abs(a.minX - b.minX) <= 1, abs(a.minY - b.minY) <= 1, abs(a.width - b.width) <= 1, abs(a.height - b.height) <= 1 {
                    matched += 1
                } else {
                    print("line \(line) h\(h) v\(v): SpriteKit \(a) shim \(b)")
                }
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    @Test("Each run draws in its own style, end to end on the baseline, raised by its offset")
    func runs() throws {
        _ = Self.engine
        let label = SpriteKitShim.SKLabelNode()
        label.attributedText = ours(Self.lines[1])
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .baseline
        let runs = try #require(label.runs)
        #expect(runs.map(\.text) == ["AB", "*", "C"])
        #expect(runs.map(\.fontSize) == [40, 20, 40])
        let layout = try #require(label.layout)
        #expect(layout.lines.count == 3)
        let origins = layout.lines.map(\.origin)
        #expect(abs(origins[1].x - (origins[0].x + layout.lines[0].line.advance)) < 0.001)
        #expect(abs(origins[2].x - (origins[1].x + layout.lines[1].line.advance)) < 0.001)
        #expect(abs(origins[1].y - origins[0].y - 10) < 0.001)
        #expect(origins[2].y == origins[0].y)
    }

    @Test("A wrapped label in several styles draws as its own text, not as runs")
    func wrapped() {
        _ = Self.engine
        let label = SpriteKitShim.SKLabelNode()
        label.attributedText = ours([Piece(text: "Hi", size: 20), Piece(text: " there you", size: 30)])
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = 120
        _ = label.layout
        #expect(label.runs != nil)
        #expect(label.laidOutRuns == nil)
    }

    @Test("One style raised off the baseline draws as a run")
    func raisedAlone() throws {
        _ = Self.engine
        let label = SpriteKitShim.SKLabelNode()
        label.attributedText = ours([Piece(text: "Up", size: 20, baselineOffset: 6)])
        label.horizontalAlignmentMode = .left
        let layout = try #require(label.layout)
        #expect(label.laidOutRuns?.count == 1)
        let plain = SpriteKitShim.SKLabelNode()
        plain.attributedText = ours([Piece(text: "Up", size: 20)])
        plain.horizontalAlignmentMode = .left
        let base = try #require(plain.layout)
        #expect(abs(layout.lines[0].origin.y - base.lines[0].origin.y - 6) < 1.001)
    }

    @Test("One style throughout draws as plain text")
    func oneStyle() {
        let label = SpriteKitShim.SKLabelNode()
        label.attributedText = ours([Piece(text: "Hel", size: 20), Piece(text: "lo", size: 20)])
        #expect(label.runs == nil)
        #expect(label.text == "Hello")
    }
}
#endif
