#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// One face of a font file on the system: a collection's faces are told
/// apart by index, a variable font's by its axis values.
public struct FallbackFace: Hashable, Sendable {
    public var path: String
    public var index: Int
    /// Axis values by tag ("wght": 600); none for the default instance.
    public var variations: [String: Double]

    public init(path: String, index: Int = 0, variations: [String: Double] = [:]) {
        self.path = path
        self.index = index
        self.variations = variations
    }
}

/// Where a character a line's own face has no glyph for is drawn from, as
/// the platform's text falls back: Core Text's cascade on Apple, the
/// system font chain (`SystemFontFallback`) on Android.
public protocol FontFallbackProvider: AnyObject, Sendable {
    /// A face with a glyph for every scalar of `character`, for text set in
    /// `font` (a face of `weight`, 100…900), or nil for none.
    func face(for character: Character, font: FontKey, weight: Int) -> FallbackFace?
}

/// How a character asks to be drawn (UTS #51): as an emoji, as text, or
/// as its default, which for most is text.
public enum EmojiPresentation: Sendable {
    case emoji, text, textByDefault

    /// FE0E asks for text; FE0F, a keycap, a skin tone, a flag or a joined
    /// sequence for an emoji; else a character whose default is emoji
    /// (⌚, ⭐, 😀) is one.
    public init(_ character: Character) {
        let scalars = character.unicodeScalars
        if scalars.contains("\u{FE0E}") {
            self = .text
        } else if scalars.contains(where: { [0xFE0F, 0x20E3, 0x200D].contains($0.value)
            || (0x1F3FB...0x1F3FF).contains($0.value) || (0x1F1E6...0x1F1FF).contains($0.value) })
            || scalars.first?.properties.isEmojiPresentation == true {
            self = .emoji
        } else {
            self = .textByDefault
        }
    }
}

extension Unicode.Scalar {
    /// Drawn as nothing by any face, so never a reason to fall back:
    /// controls, joiners, variation selectors and the like.
    var isIgnorableForFallback: Bool {
        switch value {
        case 0x00...0x1F, 0x7F...0x9F, 0x00AD, 0x034F, 0x061C, 0x180B...0x180F,
             0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F,
             0xFEFF, 0xE0000...0xE0FFF:
            return true
        default:
            return false
        }
    }
}

/// Android's own font fallback: the system's chain of families from
/// `/system/etc/font_fallback.xml` (Android 15) or `fonts.xml`, as a
/// TextView set in an app's font falls back to it. The default family
/// (sans-serif) comes first, then every unnamed family in the file's
/// order; a character goes to the first family that has it, unless a later
/// one is for a language the user reads (Minikin's locale match), and
/// within a family to the font nearest the text's weight. A character to be
/// drawn as an emoji (`EmojiPresentation`) goes to the emoji family first,
/// one to be drawn as text never does. Families for
/// the taller "elegant" variant are skipped, as TextView skips them.
public final class SystemFontFallback: FontFallbackProvider, @unchecked Sendable {
    public struct Family: Equatable, Sendable {
        public var languages: [String]
        public var fonts: [Font]

        public init(languages: [String], fonts: [Font]) {
            self.languages = languages
            self.fonts = fonts
        }
    }

    public struct Font: Equatable, Sendable {
        public var face: FallbackFace
        public var weight: Int
        public var isItalic: Bool

        public init(face: FallbackFace, weight: Int = 400, isItalic: Bool = false) {
            self.face = face
            self.weight = weight
            self.isItalic = isItalic
        }
    }

    public let families: [Family]
    /// The user's languages, most preferred first, as BCP-47 tags.
    public let languages: [String]
    private let library: FontLibrary
    /// The families for the user's languages, most preferred first, then
    /// in the chain's order: asked before the rest.
    private let preferred: [Int]
    private let lock = NSLock()
    /// A cmap lookup for each family's first font, made when first asked:
    /// HarfBuzz over the mapped file, no FreeType face, so asking costs
    /// the cmap's pages and nothing more.
    private var probes: [Int: CoverageProbe?] = [:]
    private var chosen: [Character: Int?] = [:]

    public init(families: [Family], languages: [String], library: FontLibrary = .shared) {
        self.families = families
        self.languages = languages
        self.library = library
        preferred = families.indices
            .compactMap { index in Self.rank(of: families[index], in: languages).map { (index, $0) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0)
    }

    /// The device's chain, or nil where there is no font configuration.
    public static func load(
        library: FontLibrary = .shared,
        languages: [String],
        directory: String = "/system/fonts",
        configurations: [String] = ["/system/etc/font_fallback.xml", "/system/etc/fonts.xml"]
    ) -> SystemFontFallback? {
        for path in configurations {
            guard let data = FileManager.default.contents(atPath: path),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let families = parse(xml, directory: directory)
            if !families.isEmpty {
                return SystemFontFallback(families: families, languages: languages, library: library)
            }
        }
        return nil
    }

    public func face(for character: Character, font: FontKey, weight: Int) -> FallbackFace? {
        let scalars = Array(character.unicodeScalars.filter { !$0.isIgnorableForFallback })
        guard !scalars.isEmpty else { return nil }
        let presentation = EmojiPresentation(character)
        let family = lock.withLock { () -> Int? in
            if let known = chosen[character] { return known }
            // An emoji's family first when it's to be drawn as one, never
            // when it's to be drawn as text (Minikin's emoji and variation-
            // selector matching); then a family for a language the user
            // reads (its locale match), else the first that has it.
            let covers = { (index: Int) in self.probe(index)?.covers(scalars) == true }
            let emoji = families.indices.filter { families[$0].languages.contains("und-Zsye") }
            if presentation == .emoji, let found = emoji.first(where: covers) {
                chosen[character] = found
                return found
            }
            let allowed = { (index: Int) in presentation != .text || !emoji.contains(index) }
            let found = preferred.first(where: { allowed($0) && covers($0) })
                ?? families.indices.first(where: { allowed($0) && covers($0) })
            chosen[character] = found
            return found
        }
        guard let family else { return nil }
        // The font nearest the weight, upright first (Minikin's style match).
        return families[family].fonts.min { a, b in
            (a.isItalic ? 1000 : 0) + abs(a.weight - weight) < (b.isItalic ? 1000 : 0) + abs(b.weight - weight)
        }?.face
    }

    /// Called with the lock held.
    private func probe(_ index: Int) -> CoverageProbe? {
        if let made = probes[index] { return made }
        let made = families[index].fonts.first.flatMap { font in
            library.file(atPath: font.face.path).flatMap { CoverageProbe(file: $0, index: font.face.index) }
        }
        probes[index] = made
        return made
    }

    /// How early in the user's languages the family's language comes; nil
    /// for none of them.
    private static func rank(of family: Family, in languages: [String]) -> Int? {
        for (rank, language) in languages.enumerated() {
            if family.languages.contains(where: { Self.matches(language, $0) }) { return rank }
        }
        return nil
    }

    /// Whether the user's language `user` is what a family for `family` is
    /// for: the same tag or a narrower one ("ja-JP" for "ja"), with Chinese
    /// regions read as their scripts.
    static func matches(_ user: String, _ family: String) -> Bool {
        func normalised(_ tag: String) -> String {
            let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard parts.first?.lowercased() == "zh", parts.count > 1,
                  !["hans", "hant"].contains(parts[1].lowercased()) else { return parts.joined(separator: "-").lowercased() }
            let traditional = ["tw", "hk", "mo"].contains(parts[1].lowercased())
            return (["zh", traditional ? "hant" : "hans"] + parts.dropFirst()).joined(separator: "-").lowercased()
        }
        let user = normalised(user), family = normalised(family)
        guard !family.hasPrefix("und") else { return false }
        return user == family || user.hasPrefix(family + "-")
    }

    // MARK: - The configuration

    /// The fallback chain in an Android font configuration: the sans-serif
    /// family, then each family without a name, leaving out the "elegant"
    /// variants. Each font's file is read against `directory`.
    public static func parse(_ xml: String, directory: String) -> [Family] {
        var families: [Family] = []
        var defaultFamily: Family?
        var scanner = TagScanner(xml)
        while let family = scanner.next(tag: "family") {
            let name = family.attributes["name"]
            guard name == nil || name == "sans-serif", family.attributes["variant"] != "elegant" else { continue }
            var inner = TagScanner(family.body)
            var fonts: [Font] = []
            while let font = inner.next(tag: "font") {
                // A serif face in the family serves the serif chain only.
                guard font.attributes["fallbackFor"] == nil || font.attributes["fallbackFor"] == "sans-serif" else { continue }
                // The file name is the element's text, before any <axis>.
                let file = font.body.components(separatedBy: "<").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !file.isEmpty else { continue }
                var axes = TagScanner(font.body)
                var variations: [String: Double] = [:]
                while let axis = axes.next(tag: "axis") {
                    if let tag = axis.attributes["tag"], let value = Double(axis.attributes["stylevalue"] ?? "") {
                        variations[tag] = value
                    }
                }
                fonts.append(Font(
                    face: FallbackFace(path: directory + "/" + file, index: Int(font.attributes["index"] ?? "") ?? 0,
                                       variations: variations),
                    weight: Int(font.attributes["weight"] ?? "") ?? 400,
                    isItalic: font.attributes["style"] == "italic"
                ))
            }
            guard !fonts.isEmpty else { continue }
            let entry = Family(
                languages: (family.attributes["lang"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init),
                fonts: fonts
            )
            if name == "sans-serif" {
                if defaultFamily == nil { defaultFamily = entry }
            } else {
                families.append(entry)
            }
        }
        return (defaultFamily.map { [$0] } ?? []) + families
    }
}

/// Whether a face's cmap maps characters, read by HarfBuzz straight from
/// the font file's bytes.
private final class CoverageProbe {
    private let file: FontFile
    private let font: OpaquePointer

    init?(file: FontFile, index: Int) {
        guard let face = file.hbFace(index: index), let font = hb_font_create(face) else { return nil }
        self.file = file
        self.font = font
    }

    deinit { hb_font_destroy(font) }

    func covers(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.allSatisfy { scalar in
            var glyph: hb_codepoint_t = 0
            return hb_font_get_nominal_glyph(font, scalar.value, &glyph) != 0 && glyph != 0
        }
    }
}

/// Just enough XML for a font configuration: elements by name, their
/// attributes and their bodies. Comments are skipped.
private struct TagScanner {
    struct Element {
        var attributes: [String: String]
        var body: String
    }

    private let text: String
    private var position: String.Index

    init(_ xml: String) {
        var text = xml
        while let open = text.range(of: "<!--") {
            let close = text.range(of: "-->", range: open.upperBound ..< text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(open.lowerBound ..< close)
        }
        self.text = text
        position = text.startIndex
    }

    mutating func next(tag: String) -> Element? {
        while let open = text.range(of: "<" + tag, range: position ..< text.endIndex) {
            guard open.upperBound < text.endIndex else { return nil }
            let after = text[open.upperBound]
            guard after == " " || after == ">" || after == "/" || after.isNewline || after == "\t" else {
                position = open.upperBound
                continue
            }
            guard let headEnd = text.range(of: ">", range: open.upperBound ..< text.endIndex) else { return nil }
            let head = String(text[open.upperBound ..< headEnd.lowerBound])
            let attributes = Self.attributes(head)
            if head.hasSuffix("/") {
                position = headEnd.upperBound
                return Element(attributes: attributes, body: "")
            }
            let close = text.range(of: "</" + tag + ">", range: headEnd.upperBound ..< text.endIndex)
            position = close?.upperBound ?? text.endIndex
            return Element(attributes: attributes, body: String(text[headEnd.upperBound ..< (close?.lowerBound ?? text.endIndex)]))
        }
        return nil
    }

    private static func attributes(_ head: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = Substring(head)
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[rest.index(after: equals)...].drop { $0 == " " }
            guard let quote = rest.first, quote == "\"" || quote == "'" else { break }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { break }
            attributes[name] = String(rest[..<end])
            rest = rest[rest.index(after: end)...]
        }
        return attributes
    }
}
#endif
