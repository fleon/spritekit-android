#if canImport(CTextShaping)
import CTextShaping
import Foundation
import SpriteKitShim

/// One glyph as the shaper placed it.
///
/// `cluster` is the UTF-8 byte offset of the character this glyph came from,
/// which is how shaping is checked: for Thai a glyph's cluster can run
/// *backwards* relative to the glyph before it, because the shaper reorders a
/// leading vowel to sit after the consonant it is written before. FreeType on
/// its own has no idea about that and would draw the codepoints in order.
public struct ShapedGlyph: Equatable, Sendable {
    public var glyph: UInt32
    public var cluster: Int
    public var xAdvance: CGFloat
    public var yAdvance: CGFloat
    public var xOffset: CGFloat
    public var yOffset: CGFloat

    public init(
        glyph: UInt32,
        cluster: Int,
        xAdvance: CGFloat,
        yAdvance: CGFloat = 0,
        xOffset: CGFloat = 0,
        yOffset: CGFloat = 0
    ) {
        self.glyph = glyph
        self.cluster = cluster
        self.xAdvance = xAdvance
        self.yAdvance = yAdvance
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}

/// A shaped stretch of one script, in order of drawing.
public struct ShapedRun: Equatable, Sendable {
    public var glyphs: [ShapedGlyph]
    public var script: TextScript
    /// Where this run started in the whole string, in UTF-8 bytes, so a
    /// run's clusters can be read against the original text.
    public var byteOffset: Int

    public init(glyphs: [ShapedGlyph], script: TextScript, byteOffset: Int) {
        self.glyphs = glyphs
        self.script = script
        self.byteOffset = byteOffset
    }

    /// How far the pen travels across the run.
    public var advance: CGFloat { glyphs.reduce(0) { $0 + $1.xAdvance } }
}

/// The scripts the game ships, plus `.common` for digits, spaces and
/// punctuation, which take the script of whatever they sit among.
///
/// This is not a general Unicode script property: it is only as fine as the
/// shaper needs, because every one of these is left-to-right and the game
/// uses one face for a whole label. What it is for is handing HarfBuzz the
/// right script tag, which is what turns Thai reordering on.
public enum TextScript: String, Equatable, Sendable, CaseIterable {
    case common
    case latin
    case cyrillic
    case thai
    case han
    case hiragana
    case katakana
    case hangul

    var hbScript: hb_script_t {
        switch self {
        case .common: return HB_SCRIPT_COMMON
        case .latin: return HB_SCRIPT_LATIN
        case .cyrillic: return HB_SCRIPT_CYRILLIC
        case .thai: return HB_SCRIPT_THAI
        case .han: return HB_SCRIPT_HAN
        case .hiragana: return HB_SCRIPT_HIRAGANA
        case .katakana: return HB_SCRIPT_KATAKANA
        case .hangul: return HB_SCRIPT_HANGUL
        }
    }

    /// A BCP-47 tag for the run, which some fonts switch forms on.
    var language: String {
        switch self {
        case .thai: return "th"
        case .han: return "zh"
        case .hiragana, .katakana: return "ja"
        case .hangul: return "ko"
        default: return "en"
        }
    }

    public static func of(_ scalar: Unicode.Scalar) -> TextScript {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return .latin
        case 0x0400...0x04FF, 0x0500...0x052F:
            return .cyrillic
        case 0x0E00...0x0E7F:
            return .thai
        case 0x3040...0x309F:
            return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF:
            return .katakana
        case 0x1100...0x11FF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0x3130...0x318F:
            return .hangul
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF:
            return .han
        default:
            return .common
        }
    }
}

/// Splits a string into stretches of one script each, so each is shaped with
/// the tag its script needs. `.common` runs — spaces, digits, punctuation —
/// join whatever came before them rather than becoming runs of their own.
func itemise(_ text: String) -> [(script: TextScript, range: Range<String.Index>)] {
    var runs: [(TextScript, Range<String.Index>)] = []
    var start = text.startIndex
    var current: TextScript?

    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(after: index)
        let script = text[index].unicodeScalars
            .map(TextScript.of)
            .first { $0 != .common } ?? .common

        if script != .common, let open = current, open != .common, script != open {
            runs.append((open, start..<index))
            start = index
            current = script
        } else if current == nil {
            current = script
        } else if current == .common, script != .common {
            current = script
        }
        index = next
    }

    if start < text.endIndex {
        runs.append((current ?? .common, start..<text.endIndex))
    }
    return runs
}

#endif
