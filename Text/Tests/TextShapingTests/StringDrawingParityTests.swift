#if canImport(AppKit) && os(macOS)
import AppKit
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// Text drawn into a bitmap (`TextBlock`, behind UIKit's
/// `NSAttributedString.boundingRect(with:options:context:)` and
/// `draw(in:)`) against Apple's on the same font files: the measured block
/// against AppKit's string drawing, which is UIKit's text system, and the
/// pixels against Core Text drawing into a CoreGraphics bitmap.
@Suite("Text drawn into bitmaps as Apple draws it") struct StringDrawingParityTests {
    private static let fonts: [(String, CGFloat)] = [("Montserrat-Black", 15), ("Montserrat-SemiBold", 31.5), ("KoHo-Bold", 20), ("Geneva", 12)]

    private static func appKitRect(_ text: String, font: String, size: CGFloat, width: CGFloat) throws -> CGRect {
        _ = CoreTextParityTests.registered
        let nsFont = try #require(NSFont(name: font, size: size))
        let string = NSAttributedString(string: text, attributes: [.font: nsFont])
        return string.boundingRect(with: CGSize(width: width, height: 10_000), options: .usesLineFragmentOrigin)
    }

    @Test("A block measures as AppKit measures it", arguments: fonts.map(\.0))
    func blockSizeMatches(font: String) throws {
        let size = try #require(Self.fonts.first { $0.0 == font }).1
        _ = Fonts.engine
        let key = FontKey(name: font, size: size)
        for (text, width) in [("Level Select", 10_000.0), ("Find a player", 10_000), ("Are you sure you want to quit? You will lose this game.", 160), ("One\nTwo lines", 10_000)] as [(String, CGFloat)] {
            let ours = try #require(TextBlock(text, font: key, maxWidth: width)).size
            let theirs = try Self.appKitRect(text, font: font, size: size, width: width).size
            #expect(abs(ours.width - theirs.width) < 0.01 * size, "\(font) \(text) width: \(ours.width) against \(theirs.width)")
            #expect(abs(ours.height - theirs.height) < 0.5, "\(font) \(text) height: \(ours.height) against \(theirs.height)")
        }
    }

    /// The alpha of each pixel, rows top first.
    private static func alpha(_ data: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: width * height)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width { alpha[y * width + x] = bytes[y * bytesPerRow + x * 4 + 3] }
        }
        return alpha
    }

    @Test("Glyphs land on the pixels Core Text draws them on", arguments: [CGFloat(0), 0.25, 0.5])
    func pixelsMatch(fraction: CGFloat) throws {
        _ = Fonts.engine
        _ = CoreTextParityTests.registered
        let width = 260, height = 60
        let font = "Montserrat-Black", size: CGFloat = 31.5, text = "Level Select"
        let baseline = 44.0, left = 6 + fraction

        let ours = BitmapContext(width: width, height: height)
        let block = try #require(TextBlock(text, font: FontKey(name: font, size: size), maxWidth: nil))
        block.draw(in: CGRect(x: left, y: baseline - block.ascent, width: 10_000, height: 100), alignment: .left, colour: .white, context: ours)
        let mine = try Self.alpha(#require(ours.data), width: width, height: height, bytesPerRow: width * 4)

        let theirs = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        theirs.setShouldSmoothFonts(false)
        theirs.setShouldSubpixelQuantizeFonts(false)
        theirs.setShouldSubpixelPositionFonts(true)
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
        theirs.textPosition = CGPoint(x: left, y: CGFloat(height) - baseline)
        CTLineDraw(line, theirs)
        let reference = try Self.alpha(#require(theirs.data), width: width, height: height, bytesPerRow: theirs.bytesPerRow)

        let total = reference.reduce(0) { $0 + Int($1) }
        let difference = zip(mine, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        // FreeType and Core Text antialias differently, so edges differ by a
        // little; a glyph a pixel out would differ by most of its ink.
        #expect(total > 0)
        #expect(Double(difference) < 0.12 * Double(total), "off by \(difference) of \(total)")
    }
}
#endif

#if canImport(AppKit) && os(macOS)
/// `draw(in:)` placed as AppKit places it: baselines, line spacing and
/// alignment, drawn by AppKit into a flipped context (UIKit's way up).
@Suite("Text drawn in a rect as AppKit draws it") struct StringDrawingRectParityTests {
    private static func alpha(_ context: CGContext) -> [UInt8] {
        guard let data = context.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0 ..< context.height).flatMap { y in (0 ..< context.width).map { x in bytes[y * context.bytesPerRow + x * 4 + 3] } }
    }

    @Test("Lines and alignment land where AppKit draws them", arguments: [
        (NSTextAlignment.left, TextBlock.Alignment.left), (.center, .center), (.right, .right),
    ])
    func linesMatch(appKit: NSTextAlignment, ours alignment: TextBlock.Alignment) throws {
        _ = Fonts.engine
        _ = CoreTextParityTests.registered
        let width = 200, height = 140
        let font = "Montserrat-Black", size: CGFloat = 15
        let text = "Are you sure you want to quit?\nYou will lose this game."
        let rect = CGRect(x: 10.25, y: 7.5, width: 180, height: 120)

        let ours = BitmapContext(width: width, height: height)
        let block = try #require(TextBlock(text, font: FontKey(name: font, size: size), maxWidth: rect.width))
        block.draw(in: rect, alignment: alignment, colour: .white, context: ours)
        let mineData = try #require(ours.data).assumingMemoryBound(to: UInt8.self)
        let mine = (0 ..< width * height).map { mineData[$0 * 4 + 3] }

        let theirs = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        theirs.setShouldSmoothFonts(false)
        theirs.translateBy(x: 0, y: CGFloat(height))
        theirs.scaleBy(x: 1, y: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = appKit
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: try #require(NSFont(name: font, size: size)), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: theirs, flipped: true)
        string.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        let reference = Self.alpha(theirs)

        let total = reference.reduce(0) { $0 + Int($1) }
        let difference = zip(mine, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(total > 0)
        #expect(Double(difference) < 0.15 * Double(total), "\(alignment): off by \(difference) of \(total)")
    }
}
#endif
