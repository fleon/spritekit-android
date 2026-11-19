#if canImport(SpriteKit) && os(macOS)
import Foundation
import SpriteKitShim
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
}
#endif
