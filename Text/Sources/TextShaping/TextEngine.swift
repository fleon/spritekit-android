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
    private var fallbackProvider: FontFallbackProvider?
    /// Each character's fallback face, per face it fell back from: its
    /// registered name, or nil where nothing has it.
    private var fallbackNames: [FallbackKey: String?] = [:]

    private struct FallbackKey: Hashable {
        var character: Character
        var font: String
    }

    /// Where characters a line's face has no glyph for are drawn from; nil
    /// draws them in the line's face (its .notdef), as before. Labels and
    /// string drawing both fall back through it.
    public var fallback: FontFallbackProvider? {
        get { lock.withLock { fallbackProvider } }
        set {
            lock.withLock {
                fallbackProvider = newValue
                fallbackNames.removeAll()
                measured.removeAll()
            }
        }
    }

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

    /// Shapes a string, one run per script and face. Nil when the face is
    /// unknown.
    public func shape(_ text: String, font: FontKey) -> [ShapedRun]? {
        library.face(font).map { lineRuns(text, font: font, face: $0) }
    }

    /// A line's runs in the order drawn: through the bidirectional
    /// algorithm when it has right-to-left text in it, else as it always was.
    private func lineRuns(_ text: String, font: FontKey, face: FaceHandle) -> [ShapedRun] {
        Bidi.needsReordering(text) ? shapeBidi(text, font: font, face: face) : shapeRuns(text, font: font, face: face)
    }

    /// A line with right-to-left text in it, laid out by the bidirectional
    /// algorithm (`Bidi`): its stretches of one level each shaped in that
    /// level's direction, then drawn in the order L2 puts them in. A
    /// right-to-left line's trailing spaces go last, at its right: Core Text
    /// hangs them left of the line's origin, and either way the visible
    /// glyphs start at the origin and nothing drawn moves.
    private func shapeBidi(_ text: String, font: FontKey, face: FaceHandle) -> [ShapedRun] {
        let (levels, line) = Bidi.levels(Array(text.unicodeScalars))
        var body = text.endIndex
        if line % 2 == 1 {
            while body > text.startIndex,
                  text[text.index(before: body)].unicodeScalars.allSatisfy(Bidi.isWhitespace) {
                body = text.index(before: body)
            }
        }
        // Each character at its first scalar's level.
        var stretches: [(range: Range<String.Index>, level: UInt8)] = []
        var scalar = 0
        var index = text.startIndex
        while index < body {
            let next = text.index(after: index)
            let level = levels[scalar]
            scalar += text[index].unicodeScalars.count
            if let last = stretches.last, last.level == level {
                stretches[stretches.count - 1].range = last.range.lowerBound ..< next
            } else {
                stretches.append((index ..< next, level))
            }
            index = next
        }
        func shaped(_ range: Range<String.Index>, rightToLeft: Bool) -> [ShapedRun] {
            let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            return shapeRuns(String(text[range]), font: font, face: face, rightToLeft: rightToLeft).map { run in
                var run = run
                run.byteOffset += start
                run.glyphs = run.glyphs.map { var glyph = $0; glyph.cluster += start; return glyph }
                return run
            }
        }
        var units: [(run: ShapedRun, level: UInt8)] = []
        for stretch in stretches {
            for run in shaped(stretch.range, rightToLeft: stretch.level % 2 == 1) { units.append((run, stretch.level)) }
        }
        var runs = Bidi.visualOrder(units.map(\.level)).map { units[$0].run }
        if body < text.endIndex { runs += shaped(body ..< text.endIndex, rightToLeft: true) }
        return runs
    }

    /// Characters `face` has every glyph of stay in it, as Core Text keeps
    /// them (spaces and digits among fallback text too); the rest go to the
    /// fallback face that has them, the last one used first, each stretch
    /// shaped in its own face at the line's size.
    /// `rightToLeft` shapes every run in that direction and leaves them in
    /// logical order, for `shapeBidi` to order; nil, each run in its
    /// script's, ordered here.
    private func shapeRuns(_ text: String, font: FontKey, face: FaceHandle, rightToLeft: Bool? = nil) -> [ShapedRun] {
        // An emoji (FE0F, a keycap, a flag...) comes from an emoji face even
        // where the line's face has the character, as Core Text draws it.
        let emoji = { (character: Character) in
            !face.hasColourGlyphs && EmojiPresentation(character) == .emoji
        }
        guard let provider = fallback,
              !text.unicodeScalars.allSatisfy({ $0.isIgnorableForFallback || face.covers($0) })
                // (Every emoji has a scalar from U+2190 up: a cheap look first.)
                || text.unicodeScalars.contains(where: { $0.value >= 0x2190 }) && text.contains(where: emoji) else {
            return face.shapeRuns(text, rightToLeft: rightToLeft)
        }
        var stretches: [(range: Range<String.Index>, font: String?)] = []
        var last: (name: String, face: FaceHandle)?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            let scalars = character.unicodeScalars.filter { !$0.isIgnorableForFallback }
            var name: String?
            let wantsEmoji = emoji(character)
            if wantsEmoji || !scalars.allSatisfy(face.covers) {
                if let last, last.face.hasColourGlyphs == wantsEmoji, scalars.allSatisfy(last.face.covers) {
                    name = last.name
                } else if let found = fallbackName(for: character, font: font, provider: provider),
                          let fallbackFace = library.face(FontKey(name: found, size: font.size)) {
                    name = found
                    last = (found, fallbackFace)
                }
            }
            if let open = stretches.last, open.font == name {
                stretches[stretches.count - 1].range = open.range.lowerBound ..< next
            } else {
                stretches.append((index ..< next, name))
            }
            index = next
        }
        let runs = stretches.flatMap { stretch -> [ShapedRun] in
            let shaper = stretch.font.flatMap { library.face(FontKey(name: $0, size: font.size)) } ?? face
            let start = text.utf8.distance(from: text.startIndex, to: stretch.range.lowerBound)
            return shaper.shapeRuns(String(text[stretch.range]), rightToLeft: rightToLeft).map { run in
                var run = run
                run.byteOffset += start
                run.glyphs = run.glyphs.map { var glyph = $0; glyph.cluster += start; return glyph }
                run.font = stretch.font
                return run
            }
        }
        return rightToLeft == nil ? Self.visualOrder(runs) : runs
    }

    /// Right-to-left runs, with the spaces and punctuation between them, in
    /// the order they are drawn: each such stretch reversed, as the bidi
    /// algorithm lays it out in a left-to-right line. Shaping alone keeps
    /// one script together, which is why only fallback, where a line's own
    /// face keeps the spaces, splits a right-to-left stretch.
    static func visualOrder(_ runs: [ShapedRun]) -> [ShapedRun] {
        guard runs.contains(where: \.script.isRightToLeft) else { return runs }
        var ordered: [ShapedRun] = []
        var index = 0
        while index < runs.count {
            guard runs[index].script.isRightToLeft else {
                ordered.append(runs[index])
                index += 1
                continue
            }
            // Through every later right-to-left run reached over neutrals.
            var end = index
            var probe = index + 1
            while probe < runs.count, runs[probe].script == .common || runs[probe].script.isRightToLeft {
                if runs[probe].script.isRightToLeft { end = probe }
                probe += 1
            }
            ordered.append(contentsOf: runs[index ... end].reversed())
            index = end + 1
        }
        return ordered
    }

    private func fallbackName(for character: Character, font: FontKey, provider: FontFallbackProvider) -> String? {
        let key = FallbackKey(character: character, font: font.name)
        if let known = lock.withLock({ fallbackNames[key] }) { return known }
        let weight = library.describedFace(named: font.name)?.weightClass ?? 400
        let name = provider.face(for: character, font: font, weight: weight).flatMap(library.registerFallback)
        lock.withLock { fallbackNames[key] = name }
        return name
    }

    /// The ink box of shaped runs, each glyph's from its own run's face.
    private func inkBounds(of runs: [ShapedRun], font: FontKey, face: FaceHandle) -> CGRect {
        var pen: CGFloat = 0
        var box: CGRect?
        for run in runs {
            let runFace = run.font == nil ? face : library.face(run.face(in: font)) ?? face
            for glyph in run.glyphs {
                if let outline = runFace.outlineBox(glyph.glyph) {
                    let placed = outline.offsetBy(dx: pen + glyph.xOffset, dy: glyph.yOffset)
                    box = box.map { $0.union(placed) } ?? placed
                }
                pen += glyph.xAdvance
            }
        }
        // Nothing drawn (a line of spaces) still has width, which is what a
        // centred label is positioned by.
        return box ?? CGRect(x: 0, y: 0, width: pen, height: 0)
    }

    /// Shapes and rasterises in one go: each glyph with where it sits on the
    /// atlas and where the pen is when it is drawn. This is what the
    /// renderer walks.
    public func placedGlyphs(_ text: String, font: FontKey) -> [PlacedGlyph] {
        guard let runs = shape(text, font: font) else { return [] }
        var placed: [PlacedGlyph] = []
        var pen: CGFloat = 0
        for run in runs {
            let runFont = run.face(in: font)
            for glyph in run.glyphs {
                let key = GlyphAtlas.Key(font: runFont.name, size: runFont.size, glyph: glyph.glyph)
                if let entry = atlas.glyph(key, font: runFont), !entry.isEmpty {
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
        let runs = lineRuns(text, font: font, face: face)
        let line = TextLine(
            text: text,
            advance: runs.reduce(0) { $0 + $1.advance },
            inkBounds: inkBounds(of: runs, font: font, face: face)
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
            let width = self.lineRuns(key, font: font, face: face).reduce(0) { $0 + $1.advance }
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
    public func glyphMasks(_ text: String, font: FontKey, scale: CGFloat, offset: CGPoint, positionsPerPixel: Int) -> [GlyphMask] {
        let steps = CGFloat(max(1, positionsPerPixel))
        guard scale > 0, let runs = shape(text, font: font) else { return [] }
        var masks: [GlyphMask] = []
        var pen: CGFloat = 0
        for run in runs {
            if let box = colourBox(of: run, font: font), let face = library.face(run.face(in: font)) {
                // Colour glyphs (emoji): their image in its box, snapped to whole pixels.
                let pixels = Int((box.width * scale).rounded())
                for glyph in run.glyphs {
                    let x = (offset.x + (pen + glyph.xOffset + box.minX) * scale).rounded(.down)
                    let top = (offset.y + (glyph.yOffset + box.maxY) * scale).rounded()
                    if let image = face.colourImage(glyph.glyph, pixels: pixels) {
                        masks.append(GlyphMask(origin: CGPoint(x: x, y: top), width: pixels, height: pixels,
                                               coverage: stride(from: 3, to: image.pixels.count, by: 4).map { image.pixels[$0] },
                                               colour: image.pixels))
                    }
                    pen += glyph.xAdvance
                }
                continue
            }
            guard let face = library.face(FontKey(name: run.face(in: font).name, size: font.size * scale)) else {
                pen += run.advance
                continue
            }
            for glyph in run.glyphs {
                let x = offset.x + (pen + glyph.xOffset) * scale
                let y = offset.y + glyph.yOffset * scale
                let whole = CGPoint(x: x.rounded(.down), y: y.rounded(.down))
                // The x within its pixel, floored to the size's step.
                let fraction = CGPoint(x: ((x - whole.x) * steps).rounded(.down) / steps, y: y - whole.y)
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

    /// Where a run's glyphs are drawn when its face is a colour face
    /// (emoji): Apple Color Emoji's box at `font`'s size, from the pen on
    /// the baseline, y up; their pixels come from `GlyphAtlas.colourGlyph`.
    /// Nil for any other run.
    public func colourBox(of run: ShapedRun, font: FontKey) -> CGRect? {
        guard let face = library.face(run.face(in: font)), face.hasColourGlyphs else { return nil }
        return EmojiMetrics.box(font.size)
    }

    /// Each character's advance in the shaped line: every glyph's advance
    /// goes to the character its cluster starts at.
    public func characterAdvances(_ text: String, font: FontKey) -> [CGFloat] {
        guard let runs = shape(text, font: font) else { return text.map { _ in 0 } }
        // UTF-8 offset of each character's start.
        var starts: [Int] = []
        var offset = 0
        for character in text {
            starts.append(offset)
            offset += character.utf8.count
        }
        var advances = [CGFloat](repeating: 0, count: starts.count)
        for run in runs {
            for glyph in run.glyphs {
                // The last character starting at or before the cluster.
                var low = 0, high = starts.count - 1, found = 0
                while low <= high {
                    let mid = (low + high) / 2
                    if starts[mid] <= glyph.cluster { found = mid; low = mid + 1 } else { high = mid - 1 }
                }
                if !advances.isEmpty { advances[found] += glyph.xAdvance }
            }
        }
        return advances
    }

    /// The line's glyph outlines, shaped as it's measured, each moved to its
    /// pen position.
    public func glyphOutline(_ text: String, font: FontKey) -> [PathElement] {
        guard let runs = shape(text, font: font) else { return [] }
        var elements: [PathElement] = []
        var pen: CGFloat = 0
        for run in runs {
            guard let face = library.face(run.face(in: font)) else {
                pen += run.advance
                continue
            }
            for glyph in run.glyphs {
                let dx = pen + glyph.xOffset, dy = glyph.yOffset
                func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
                for element in face.outline(glyph.glyph) {
                    switch element {
                    case let .move(p): elements.append(.move(move(p)))
                    case let .line(p): elements.append(.line(move(p)))
                    case let .quadCurve(to, control): elements.append(.quadCurve(to: move(to), control: move(control)))
                    case let .curve(to, c1, c2): elements.append(.curve(to: move(to), control1: move(c1), control2: move(c2)))
                    case .close, .arc: elements.append(element)
                    }
                }
                pen += glyph.xAdvance
            }
        }
        return elements
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
