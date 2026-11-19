#if canImport(SpriteKit) && os(macOS)
import AppKit
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// A wrapped attributed label whose paragraph style right-aligns it: as
/// SpriteKit draws it on a Mac, each line ends on the block's right edge
/// (left-aligned, and without a style, each starts on its left), wherever
/// the alignment mode puts the block.
@Suite("Paragraph alignment in labels of several lines", .serialized)
@MainActor
struct ParagraphAlignmentTests {
    private struct Font: LabelFont {
        var fontName: String
        var pointSize: CGFloat
    }

    private static let text = "(v) to provide with a straight, slender piece of material"

    private func label(alignment: NSTextAlignment?, mode: SKLabelHorizontalAlignmentMode) -> SpriteKitShim.SKLabelNode {
        _ = Fonts.engine
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key("NSFont"): Font(fontName: "Montserrat-Black", pointSize: 14)]
        if let alignment {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            attributes[NSAttributedString.Key("NSParagraphStyle")] = style
        }
        let node = SpriteKitShim.SKLabelNode()
        node.attributedText = NSAttributedString(string: Self.text, attributes: attributes)
        node.numberOfLines = 0
        node.preferredMaxLayoutWidth = 180
        node.horizontalAlignmentMode = mode
        return node
    }

    /// Each line's ink extent, left and right, in the node's space.
    private func edges(_ node: SpriteKitShim.SKLabelNode) throws -> [(left: CGFloat, right: CGFloat)] {
        let layout = try #require(node.layout)
        return layout.lines.map { ($0.origin.x + $0.line.inkBounds.minX, $0.origin.x + $0.line.inkBounds.maxX) }
    }

    @Test("Right-aligned lines end together, in every alignment mode")
    func rightAligned() throws {
        for mode in [SKLabelHorizontalAlignmentMode.left, .center, .right] {
            let lines = try edges(label(alignment: .right, mode: mode))
            #expect(lines.count >= 2)
            let rights = lines.map(\.right)
            #expect((rights.max() ?? 0) - (rights.min() ?? 0) < 1.5, "\(mode.rawValue): \(rights)")
        }
    }

    @Test("Left-aligned lines, and lines with no style, start together")
    func leftAligned() throws {
        for alignment in [NSTextAlignment.left, nil] {
            let lines = try edges(label(alignment: alignment, mode: .right))
            #expect(lines.count >= 2)
            let lefts = lines.map(\.left)
            #expect((lefts.max() ?? 0) - (lefts.min() ?? 0) < 1.5, "\(String(describing: alignment)): \(lefts)")
            let rights = lines.map(\.right)
            #expect((rights.max() ?? 0) - (rights.min() ?? 0) > 5)
        }
    }

    @Test("The block's frame doesn't move")
    func frameUnchanged() {
        #expect(label(alignment: .right, mode: .right).contentFrame == label(alignment: nil, mode: .right).contentFrame)
    }
}
#endif
