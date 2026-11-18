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

    @Test("A trailing newline starts no line, and trailing spaces add no width, as in SpriteKit", arguments: ["Montserrat-SemiBold", "KoHo-Bold"])
    func trailingNewlinesAndSpaces(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        for size in [13, 20] as [CGFloat] {
            for text in ["Hx\n", "H\nH\n", "Hx   \nH", "Level \nSelect  ", "A\n\nB", "gpqy  "] {
                for (h, v) in [(0, 0), (1, 1), (2, 2), (1, 3)] {
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
                        print("\(font) \(size) '\(text.debugDescription)' h\(h) v\(v): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
                    }
                }
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    @Test("Each line's ink lands where SpriteKit draws it", arguments: ["Montserrat-SemiBold", "KoHo-Bold"])
    func linePositions(font: String) throws {
        _ = Self.registered
        _ = Fonts.engine
        let view = SpriteKit.SKView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        view.presentScene(SpriteKit.SKScene(size: CGSize(width: 600, height: 600)))
        let text = "Hx\nlonger second line\nB"
        for (h, v) in [(1, 0), (0, 1), (2, 2)] {
            let apple = SpriteKit.SKLabelNode(fontNamed: font)
            apple.fontSize = 20
            apple.numberOfLines = 0
            apple.text = text
            apple.fontColor = .white
            apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
            apple.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!
            let ours = SpriteKitShim.SKLabelNode(fontNamed: font)
            ours.fontSize = 20
            ours.numberOfLines = 0
            ours.text = text
            ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
            ours.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
            let layout = try #require(ours.layout)
            let image = try #require(view.texture(from: apple)?.cgImage())
            let ink = Self.ink(image, frame: apple.frame)
            for (index, placed) in layout.lines.enumerated() {
                // Ours, from the frame's top-left corner, y down.
                let box = placed.line.inkBounds.offsetBy(dx: placed.origin.x, dy: placed.origin.y)
                let left = box.minX - layout.bounds.minX, top = layout.bounds.maxY - box.maxY
                let band = (top: top - 2, bottom: layout.bounds.maxY - box.minY + 2)
                let theirs = try #require(ink.first { abs($0.top - top) < 1.5 && $0.top >= band.top && $0.top <= band.bottom }, "\(font) h\(h) v\(v) line \(index): no ink near \(top)")
                #expect(abs(theirs.left - left) < 1, "\(font) h\(h) v\(v) line \(index): left \(left) against SpriteKit's \(theirs.left)")
            }
        }
    }

    /// The rows of ink in a rendered label, each its top and leftmost column
    /// in points from the frame's top-left corner.
    private static func ink(_ image: CGImage, frame: CGRect) -> [(top: CGFloat, left: CGFloat)] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / frame.width
        var bands: [(top: CGFloat, left: CGFloat)] = []
        var inBand = false, top = 0, left = width
        for y in 0..<height {
            var rowLeft = width
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 128 { rowLeft = min(rowLeft, x); break }
            if rowLeft < width {
                if !inBand { inBand = true; top = y; left = rowLeft } else { left = min(left, rowLeft) }
            } else if inBand {
                inBand = false
                bands.append((CGFloat(top) / scale, CGFloat(left) / scale))
            }
        }
        if inBand { bands.append((CGFloat(top) / scale, CGFloat(left) / scale)) }
        return bands
    }

    private static func compare(_ font: String, _ size: CGFloat, _ text: String, lines: Int, width: CGFloat = 0,
                                checked: inout Int, matched: inout Int) {
        for (h, v) in [(0, 0), (1, 1), (2, 2), (1, 3), (0, 2), (2, 1)] {
            let apple = SpriteKit.SKLabelNode(fontNamed: font)
            apple.fontSize = size
            apple.numberOfLines = lines
            apple.preferredMaxLayoutWidth = width
            apple.text = text
            apple.horizontalAlignmentMode = SpriteKit.SKLabelHorizontalAlignmentMode(rawValue: h)!
            apple.verticalAlignmentMode = SpriteKit.SKLabelVerticalAlignmentMode(rawValue: v)!
            let ours = SpriteKitShim.SKLabelNode(fontNamed: font)
            ours.fontSize = size
            ours.numberOfLines = lines
            ours.preferredMaxLayoutWidth = width
            ours.text = text
            ours.horizontalAlignmentMode = SpriteKitShim.SKLabelHorizontalAlignmentMode(rawValue: h)!
            ours.verticalAlignmentMode = SpriteKitShim.SKLabelVerticalAlignmentMode(rawValue: v)!
            checked += 1
            if apple.frame == ours.contentFrame { matched += 1 } else {
                print("\(font) \(size) '\(text.debugDescription)' n\(lines) w\(width) h\(h) v\(v): SpriteKit \(apple.frame) shim \(ours.contentFrame)")
            }
        }
    }

    @Test("Empty and blank labels frame as SpriteKit's do", arguments: ["Montserrat-SemiBold", "KoHo-Bold"])
    func emptyLabels(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        for text in ["", " ", "\n", "\n\n", "  ", "   "] {
            for lines in [0, 1, 2] {
                Self.compare(font, 20, text, lines: lines, checked: &checked, matched: &matched)
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    // Montserrat's lighter instances leave out: their advances come out a
    // hair off Core Text's (HarfBuzz rounds the instance deltas), and a
    // wrapped line within a thousandth of a whole point rounds the frame the
    // other way.
    // Geneva has a line gap, which decides at some sizes whether a wrapped
    // paragraph keeps n or n + 1 lines.
    @Test("numberOfLines fits lines into SpriteKit's frame of (n + 1) times the text's own height", arguments: ["Montserrat-Black", "KoHo-Bold", "Geneva"])
    func lineLimits(font: String) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        let long = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
        for size in [11, 13, 20, 26, 33] as [CGFloat] {
            for lines in [2, 3, 4, 7, 15, 22, 30] {
                Self.compare(font, size, "A\nB\nC\nD\nE", lines: lines, checked: &checked, matched: &matched)
                Self.compare(font, size, long, lines: lines, width: size * 6, checked: &checked, matched: &matched)
                Self.compare(font, size, "Hx\n" + long, lines: lines, width: size * 6, checked: &checked, matched: &matched)
            }
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
    }

    @Test("A whole ascent and descent rounds the height up as SpriteKit's does", arguments: [10, 20, 30, 40] as [CGFloat])
    func wholeMetrics(size: CGFloat) {
        _ = Self.registered
        _ = Fonts.engine
        var checked = 0, matched = 0
        for text in ["Hx", "Hx\nHx"] {
            Self.compare("Montserrat-SemiBold", size, text, lines: 0, checked: &checked, matched: &matched)
            Self.compare("KoHo-Bold", size, text, lines: 0, checked: &checked, matched: &matched)
        }
        #expect(matched == checked, "\(matched) of \(checked) frames match")
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
