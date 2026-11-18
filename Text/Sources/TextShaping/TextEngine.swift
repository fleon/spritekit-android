#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// The text stack as the shim sees it.
///
/// `install()` is the one call the app makes at start-up, after the font
/// files are where it can read them. Everything above — `SKLabelNode`'s
/// layout, `UIFont`'s metrics — goes through the `TextProvider` this
/// registers, so nothing else in a game or the layer links FreeType.
public final class TextEngine: TextProvider, FontCatalog, @unchecked Sendable {
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

    /// Registers the font files in `directory` and takes over text for the
    /// layer. `files` names them without their `.ttf`, in the order to
    /// register them; nil registers every `.ttf` there, sorted by name. The
    /// first registered is also what a label with no `fontName` falls back
    /// to.
    @discardableResult
    public static func install(fontsAt directory: String, files: [String]? = nil) throws -> TextEngine {
        let engine = TextEngine.shared
        let names = files ?? ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".ttf") }
            .map { String($0.dropLast(4)) }
            .sorted()
        for name in names {
            let path = directory + "/" + name + ".ttf"
            if FileManager.default.fileExists(atPath: path) {
                try engine.library.register(path: path)
            }
        }
        engine.install()
        return engine
    }

    /// Registers fonts handed over as bytes, for a platform where they are
    /// not files.
    ///
    /// On Android they are assets inside the APK, which is a zip rather than
    /// a directory — there is no path to open. Extracting them first would
    /// mean a second copy of every font on disk (a large variable font can
    /// be tens of megabytes) and the same bytes in memory afterwards, so the
    /// shell reads them through the asset manager and hands them here.
    @discardableResult
    public static func install(fonts: [(name: String, data: Data)]) throws -> TextEngine {
        let engine = TextEngine.shared
        for font in fonts {
            try engine.library.register(data: font.data, name: font.name)
        }
        engine.install()
        return engine
    }

    /// Takes over text for the layer without touching the file system, for
    /// tests and for an app that loads its fonts from its own bundle.
    public func install() {
        TextMetrics.provider = self
        TextMetrics.catalog = self
    }

    // MARK: - FontCatalog

    /// The files the game itself has registered, by name without extension
    /// (the shell registers the APK's `fonts/` by those names at launch).
    private var registeredByGame: Set<String> = []
    private var systemFaces: [String] = []

    public var systemFaceNames: [String] {
        lock.withLock { systemFaces }
    }

    public func faceNames(inFontAt path: String) -> [String]? {
        if let known = library.faces(ofFile: path) ?? library.faces(ofFile: Self.fileName(path)) {
            return known
        }
        return try? FontLibrary.faces(ofFontAt: path)
    }

    public func registerFont(at path: String) -> FontRegistration {
        let name = Self.fileName(path)
        if lock.withLock({ registeredByGame.contains(name) }) { return .alreadyRegistered }
        // Registered by the shell at launch from the APK: the same bytes, so
        // not read a second time.
        if library.faces(ofFile: name) == nil {
            guard (try? library.register(path: path)) != nil else { return .unreadable }
        }
        lock.withLock { _ = registeredByGame.insert(name) }
        return .registered
    }

    public func hasFace(named name: String) -> Bool {
        library.hasName(name)
    }

    public func face(named name: String) -> CatalogFace? {
        library.describedFace(named: name)
    }

    public func faces(inFamily family: String) -> [CatalogFace] {
        library.describedFaces(inFamily: family)
    }

    /// Registers the device's own face as the system font: Roboto, which
    /// on Android 12 and later is one variable file whose named instances are
    /// its weights, and before that a file a weight. What
    /// `UIFont.systemFont(ofSize:weight:)` draws with (`SystemFontFaces`).
    @discardableResult
    public func registerSystemFonts(in directory: String = "/system/fonts") -> [String] {
        var faces: [String] = []
        let variable = directory + "/Roboto-Regular.ttf"
        if let registered = try? library.register(path: variable), !registered.isEmpty {
            faces = library.faces(ofFile: variable) ?? []
        }
        if faces.count <= 1 {
            for style in ["Thin", "Light", "Medium", "Bold", "Black"] {
                let path = "\(directory)/Roboto-\(style).ttf"
                guard FileManager.default.fileExists(atPath: path),
                      (try? library.register(path: path)) != nil
                else { continue }
                faces += library.faces(ofFile: path) ?? []
            }
        }
        lock.withLock { systemFaces = faces }
        return faces
    }

    private static func fileName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
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

    public func breakOffsets(in text: String) -> [Int] {
        LineBreak.opportunities(in: text).map { $0.utf16Offset(in: text) }
    }

    /// Shaped at `font`'s size and rasterised at `scale` times it, as the
    /// renderer draws labels, each glyph at its exact pen position: the
    /// whole pixels go into its mask's origin and the rest into the outline
    /// before FreeType renders it. Not cached in the atlas: a bitmap a game
    /// draws text into is made once.
    public func glyphMasks(_ text: String, font: FontKey, scale: CGFloat, offset: CGPoint) -> [GlyphMask] {
        guard scale > 0, let runs = shape(text, font: font),
              let face = library.face(FontKey(name: font.name, size: font.size * scale)) else { return [] }
        var masks: [GlyphMask] = []
        var pen: CGFloat = 0
        for run in runs {
            for glyph in run.glyphs {
                let x = offset.x + (pen + glyph.xOffset) * scale
                let y = offset.y + glyph.yOffset * scale
                let whole = CGPoint(x: x.rounded(.down), y: y.rounded(.down))
                let fraction = CGPoint(x: x - whole.x, y: y - whole.y)
                let mask = face.renderGlyph(glyph.glyph, offset: fraction) { pixels, width, height, pitch, left, top -> GlyphMask? in
                    guard let pixels, width > 0, height > 0, pitch >= width else { return nil }
                    var coverage = [UInt8](repeating: 0, count: width * height)
                    for row in 0 ..< height {
                        for column in 0 ..< width { coverage[row * width + column] = pixels[row * pitch + column] }
                    }
                    return GlyphMask(origin: CGPoint(x: whole.x + CGFloat(left), y: whole.y + CGFloat(top)),
                                     width: width, height: height, coverage: coverage)
                }
                if let mask = mask ?? nil { masks.append(mask) }
                pen += glyph.xAdvance
            }
        }
        return masks
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
