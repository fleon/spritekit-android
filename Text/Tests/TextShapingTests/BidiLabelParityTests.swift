#if canImport(SpriteKit) && os(macOS)
import Foundation
@testable import SpriteKitShim
import Testing
@testable import TextShaping

/// Labels of right-to-left and mixed text against SpriteKit's, as a Mac
/// drew them (macOS 27.2, Montserrat Black 15 with Core Text's fallback for
/// Arabic and Hebrew, rendered at 2x): the frame, and each line's ink from
/// left to right in the label's space. A right-to-left paragraph's lines end
/// on the block's right edge; a left-to-right one's start on its left.
@Suite("Right-to-left labels as SpriteKit lays them out", .serialized)
@MainActor
struct BidiLabelParityTests {
    struct Case {
        var text: String
        var mode: SKLabelHorizontalAlignmentMode
        var lines: Int   // numberOfLines: 1, or 0 wrapped at 160
        var frame: (x: CGFloat, width: CGFloat)
        var ink: [(CGFloat, CGFloat)]
    }

    static let cases: [Case] = [
        Case(text: "سلام عليكم", mode: .left, lines: 1, frame: (0, 70), ink: [(1, 68.5)]),
        Case(text: "سلام عليكم", mode: .center, lines: 1, frame: (-35, 70), ink: [(-34, 33.5)]),
        Case(text: "سلام عليكم", mode: .right, lines: 1, frame: (-70, 70), ink: [(-69, -1.5)]),
        Case(text: "!שלום", mode: .left, lines: 1, frame: (0, 42), ink: [(1, 41)]),
        Case(text: "نقطة 120 Score", mode: .center, lines: 1, frame: (-56, 112), ink: [(-55, 54.5)]),
        Case(text: "سلام عليكم ورحمة الله وبركاته", mode: .left, lines: 0, frame: (0, 133), ink: [(2, 132), (89, 132)]),
        Case(text: "سلام عليكم ورحمة الله وبركاته", mode: .center, lines: 0, frame: (-66, 133), ink: [(-64, 66), (23, 66)]),
        Case(text: "سلام عليكم ورحمة الله وبركاته", mode: .right, lines: 0, frame: (-133, 133), ink: [(-131, -1), (-44, -1)]),
        Case(text: "مرحبا Hello world again and more", mode: .left, lines: 0, frame: (0, 135), ink: [(1.5, 134), (6.5, 134)]),
        Case(text: "Hello עולם and مرحبا again friend", mode: .left, lines: 0, frame: (0, 158), ink: [(1.5, 156.5), (1, 99.5)]),
    ]

    @Test("Frames and each line's ink match SpriteKit's")
    func labels() {
        let font = Fonts.display(15)
        for test in Self.cases {
            let label = SKLabelNode(fontNamed: font.name)
            label.fontSize = font.size
            label.text = test.text
            label.horizontalAlignmentMode = test.mode
            label.numberOfLines = test.lines
            if test.lines == 0 { label.preferredMaxLayoutWidth = 160 }
            let frame = label.contentFrame
            let name = "'\(test.text)' mode \(test.mode.rawValue)"
            #expect(frame.minX == test.frame.x && frame.width == test.frame.width, "\(name) frame \(frame)")
            let lines = label.layout?.lines ?? []
            #expect(lines.count == test.ink.count, "\(name) lines")
            for (placed, expected) in zip(lines, test.ink) {
                let left = placed.origin.x + placed.line.inkBounds.minX
                let right = placed.origin.x + placed.line.inkBounds.maxX
                // The rendering's ink is to its half-point pixels.
                #expect(abs(left - expected.0) <= 1 && abs(right - expected.1) <= 1, "\(name) ink \(left)…\(right)")
            }
        }
    }

    private struct Font: LabelFont {
        var fontName: String
        var pointSize: CGFloat
    }

    /// Attributed labels in two faces (Montserrat Black 15, SemiBold 20),
    /// each run its own colour, as SpriteKit drew them: the frame, and each
    /// run's ink across, line by line, from the top. The runs are drawn in
    /// the bidirectional algorithm's order across them, and a right-to-left
    /// line ends on the block's right edge.
    static let styled: [(runs: [(String, Bool)], frame: CGFloat, ink: [[Int: (CGFloat, CGFloat)]])] = [
        ([("שלום ", false), ("world", true), (" עולם", false)], 140, [[0: (103.5, 138.5), 1: (40, 97.5), 2: (2, 35)]]),
        ([("Hello ", false), ("שלום", true), (" עולם", false), (" end", false)], 170,
         [[0: (1.5, 42.5), 1: (86, 132.5), 2: (47.5, 81), 3: (138, 168)]]),
        ([("مرحبا ", false), ("2026", true), (" سنة", false)], 121, [[0: (86, 120), 1: (31, 79.5), 2: (1.5, 26.5)]]),
        ([("שלום ", false), ("עולם", true), ("\nHello ", false), ("שלום", true)], 96,
         [[0: (59.5, 94.5), 1: (9.5, 54)], [2: (2, 42.5), 3: (47.5, 94)]]),
    ]
    static let colours: [SKColor] = [.red, .green, .blue, .white]

    @Test("Runs in several styles are drawn in the bidirectional algorithm's order, as SpriteKit draws them")
    func styledRuns() throws {
        _ = Fonts.engine
        for test in Self.styled {
            let text = NSMutableAttributedString()
            for (index, (string, large)) in test.runs.enumerated() {
                text.append(NSAttributedString(string: string, attributes: [
                    NSAttributedString.Key("NSFont"): large ? Font(fontName: "Montserrat-SemiBold", pointSize: 20) : Font(fontName: "Montserrat-Black", pointSize: 15),
                    NSAttributedString.Key("NSColor"): Self.colours[index],
                ]))
            }
            let label = SKLabelNode()
            label.attributedText = text
            label.numberOfLines = 0
            label.horizontalAlignmentMode = .left
            let name = "'\(text.string)'"
            #expect(label.contentFrame.width == test.frame, "\(name) frame \(label.contentFrame)")
            let placed = try #require(label.layout?.lines)
            let runs = try #require(label.laidOutRuns)
            #expect(placed.count == runs.count, "\(name)")
            // Each line's pieces, by the run (colour) they were drawn in.
            var lines: [CGFloat: [Int: (CGFloat, CGFloat)]] = [:]
            for (piece, run) in zip(placed, runs) where !piece.line.inkBounds.isEmpty {
                let colour = try #require(Self.colours.firstIndex { $0 == run.color })
                let left = piece.origin.x + piece.line.inkBounds.minX, right = piece.origin.x + piece.line.inkBounds.maxX
                let y = piece.origin.y.rounded()   // (no baseline offsets here)
                let known = lines[y]?[colour]
                lines[y, default: [:]][colour] = known.map { (min($0.0, left), max($0.1, right)) } ?? (left, right)
            }
            let ordered = lines.keys.sorted(by: >).map { lines[$0]! }
            #expect(ordered.count == test.ink.count, "\(name) lines")
            for (ours, theirs) in zip(ordered, test.ink) {
                for (colour, span) in theirs {
                    let mine = try #require(ours[colour], "\(name) run \(colour)")
                    #expect(abs(mine.0 - span.0) <= 1 && abs(mine.1 - span.1) <= 1, "\(name) run \(colour): \(mine) against \(span)")
                }
            }
        }
    }
}
#endif
