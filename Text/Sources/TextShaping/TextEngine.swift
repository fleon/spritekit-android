#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// The text stack as the shim sees it.
///
/// `install()` is the one call the app makes at start-up, after the font
/// files are where it can read them. Everything above — `SKLabelNode`'s
/// layout, `UIFont`'s metrics — goes through the `TextProvider` this
/// registers, so nothing else in the game or the layer links FreeType.
public final class TextEngine: TextProvider, @unchecked Sendable {
    public static let shared = TextEngine()

    public let library: FontLibrary
    public let atlas: GlyphAtlas

    private let lock = NSLock()
    private var measured: [Measure: TextLine] = [:]

    private struct Measure: Hashable {
        var text: String
        var font: String
        var size: Int
    }

    public init(library: FontLibrary = .shared, atlas: GlyphAtlas = .shared) {
        self.library = library
        self.atlas = atlas
    }

    /// Registers the game's three font files and takes over text for the
    /// layer. `directory` is wherever `Assets/Fonts` ended up on the device.
    @discardableResult
    public static func install(fontsAt directory: String) throws -> TextEngine {
        let engine = TextEngine.shared
        for name in ["ChironGoRoundTC-Variable", "KoHo-Bold", "Montserrat"] {
            let path = directory + "/" + name + ".ttf"
            if FileManager.default.fileExists(atPath: path) {
                try engine.library.register(path: path)
            }
        }
        TextMetrics.provider = engine
        return engine
    }

    /// Takes over text for the layer without touching the file system, for
    /// tests and for an app that loads its fonts from its own bundle.
    public func install() {
        TextMetrics.provider = self
    }

    // MARK: - Shaping

    /// Shapes a string, one run per script. Nil when the face is unknown.
    public func shape(_ text: String, font: FontKey) -> [ShapedRun]? {
        library.face(font).map { $0.shapeRuns(text) }
    }

    /// Shapes and rasterises in one go: each glyph with where it sits on the
    /// atlas and where the pen is when it is drawn. This is what the
    /// renderer walks.
    public func placedGlyphs(_ text: String, font: FontKey) -> [PlacedGlyph] {
        guard let runs = shape(text, font: font) else { return [] }
        var placed: [PlacedGlyph] = []
        var pen: CGFloat = 0
        for run in runs {
            for glyph in run.glyphs {
                let key = GlyphAtlas.Key(font: font.name, size: font.size, glyph: glyph.glyph)
                if let entry = atlas.glyph(key, font: font), !entry.isEmpty {
                    placed.append(PlacedGlyph(
                        atlas: entry,
                        origin: CGPoint(x: pen + glyph.xOffset, y: glyph.yOffset),
                        cluster: glyph.cluster
                    ))
                }
                pen += glyph.xAdvance
            }
        }
        return placed
    }

    // MARK: - TextProvider

    public func fontMetrics(_ font: FontKey) -> FontMetrics? {
        library.face(font)?.metrics
    }

    public func measure(_ text: String, font: FontKey) -> TextLine {
        let key = Measure(text: text, font: font.name, size: Int((font.size * 64).rounded()))
        if let cached = lock.withLock({ measured[key] }) { return cached }

        guard let face = library.face(font) else {
            return TextLine(text: text, advance: 0, inkBounds: .zero)
        }
        let runs = face.shapeRuns(text)
        let line = TextLine(
            text: text,
            advance: runs.reduce(0) { $0 + $1.advance },
            inkBounds: face.inkBounds(of: runs)
        )
        lock.withLock { measured[key] = line }
        return line
    }

    public func breakLines(_ text: String, font: FontKey, maxWidth: CGFloat) -> [String] {
        guard let face = library.face(font) else { return [text] }
        var widths: [String: CGFloat] = [:]
        return LineBreak.wrap(text, maxWidth: maxWidth) { piece in
            let key = String(piece)
            if let known = widths[key] { return known }
            let width = face.shapeRuns(key).reduce(0) { $0 + $1.advance }
            widths[key] = width
            return width
        }
    }

    /// Drops the measurement cache. The atlas and the faces stay.
    public func flush() {
        lock.withLock { measured.removeAll() }
    }
}

/// A glyph ready to draw: its atlas entry and where its pen sits, relative
/// to the start of the line on the baseline.
public struct PlacedGlyph: Equatable, Sendable {
    public var atlas: AtlasGlyph
    public var origin: CGPoint
    public var cluster: Int

    /// The rectangle to draw it in, in points, y up from the baseline.
    public var frame: CGRect {
        CGRect(
            x: origin.x + atlas.bearing.x,
            y: origin.y + atlas.bearing.y - atlas.size.height,
            width: atlas.size.width,
            height: atlas.size.height
        )
    }
}

#endif
