#if canImport(CTextShaping)
import Foundation
import SpriteKitShim

/// Where a line may be broken.
///
/// This is not Unicode UAX #14, and not ICU: an app need not ship ICU and
/// the Swift SDK for Android carries no line-break tables. What it does
/// cover is the three cases the scripts in `TextScript` need.
///
/// - Space-separated scripts break after spaces, and after a hyphen. A
///   no-break space (U+00A0) holds its neighbours together, as UAX #14's
///   glue does: a game can join "Quiet Harbour · Level 1" with them so a
///   line breaks before the place, never in it.
/// - Chinese, Japanese and Korean break between almost any two characters
///   (Korean between syllables, its spaces as well), held off
///   only by the small kinsoku set below — no closing bracket or full stop
///   starts a line, and no opening bracket ends one.
/// - Thai writes without spaces and is broken with a dictionary. There's
///   none here: the platform's is asked (`ThaiLineBreaks.provider`, ICU's
///   line breaks on Android and on Apple), as Core Text breaks Thai with
///   ICU's. With none installed the fallback is a
///   break at each grapheme-cluster boundary *except* straight after a
///   leading vowel (เ แ โ ใ ไ), which is written before the consonant it
///   sounds after and must never be left stranded at the end of a line. It
///   breaks mid-word, which is wrong and visible; it never breaks a cluster,
///   which would be wrong and unreadable.
enum LineBreak {
    /// Indices in `text` where a line may start.
    static func opportunities(in text: String) -> [String.Index] {
        var places: [String.Index] = []
        var index = text.startIndex
        let thaiBreaks = ThaiLineBreaks.lineStarts(in: text)

        while index < text.endIndex {
            let next = text.index(after: index)
            guard next < text.endIndex else { break }

            let here = text[index]
            let after = text[next]

            if here == " " {
                if after != " " { places.append(next) }
            } else if here == "-" || here == "\u{2010}" {
                places.append(next)
            } else if isThai(after), isThai(here) {
                if let thaiBreaks {
                    if thaiBreaks.contains(next) { places.append(next) }
                } else if !isThaiLeadingVowel(here), !startsWithMark(after) {
                    places.append(next)
                }
            } else if isIdeographic(here) || isIdeographic(after) {
                // Never either side of a straight quote (UAX #14's LB19),
                // which could open or close.
                if !noStart(after), !noEnd(here), after != " ", here != "\"", after != "\"", here != "'", after != "'" {
                    places.append(next)
                }
            }
            index = next
        }
        return places
    }

    static func isThai(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x0E00...0x0E7F).contains(Int($0.value)) } ?? false
    }

    private static func isThaiLeadingVowel(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x0E40...0x0E44).contains(Int($0.value)) } ?? false
    }

    /// A grapheme whose first scalar is a combining mark belongs to what
    /// came before it, whatever the cluster rules made of it.
    private static func startsWithMark(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.generalCategory == .nonspacingMark
            || scalar.properties.generalCategory == .spacingMark
            || scalar.properties.generalCategory == .enclosingMark
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch TextScript.of(scalar) {
        // Hangul breaks between its syllables too (UAX #14's default, as
        // Core Text breaks Korean), not only at its spaces.
        case .han, .hiragana, .katakana, .hangul: return true
        default:
            // CJK punctuation, which breaks with the characters around it.
            return (0x3000...0x303F).contains(Int(scalar.value))
                || (0xFF00...0xFFEF).contains(Int(scalar.value))
        }
    }

    private static let noStartSet: Set<Character> = [
        "。", "、", "，", "．", "：", "；", "！", "？", "）", "】", "」", "』", "》", "〕", "｝",
        "〉", "・", "ー", "ゝ", "ゞ", "々", "％", "℃", ")", "]", "}", ",", ".", "!", "?", ":", ";",
    ]
    private static let noEndSet: Set<Character> = [
        "（", "【", "「", "『", "《", "〔", "｛", "〈", "(", "[", "{",
    ]

    private static func noStart(_ character: Character) -> Bool { noStartSet.contains(character) }
    private static func noEnd(_ character: Character) -> Bool { noEndSet.contains(character) }

    /// Greedily fills lines up to `maxWidth`, measuring each candidate with
    /// `width`. A single word wider than the line is left over-wide rather
    /// than cut, as CoreText leaves it.
    static func wrap(
        _ text: String,
        maxWidth: CGFloat,
        width: (Substring) -> CGFloat
    ) -> [String] {
        guard maxWidth > 0, !text.isEmpty else { return [text] }

        let places = opportunities(in: text)
        guard !places.isEmpty else { return [text] }

        var lines: [String] = []
        var start = text.startIndex
        var lastFit: String.Index?

        // Spaces a line ends on hang past its edge, as Core Text lets them.
        func fits(_ piece: Substring) -> Bool { width(withoutTrailingSpaces(piece)) <= maxWidth }

        for place in places {
            if fits(text[start..<place]) {
                lastFit = place
                continue
            }
            // This break is already too far. Take the last one that fitted,
            // or this one if nothing did — a word on its own, over-wide.
            let cut = lastFit ?? place
            lines.append(trimmed(text[start..<cut]))
            start = cut
            lastFit = fits(text[start..<place]) ? place : nil
        }

        if start < text.endIndex {
            let tail = text[start...]
            if fits(tail) || lastFit == nil {
                lines.append(trimmed(tail))
            } else {
                lines.append(trimmed(text[start..<lastFit!]))
                lines.append(trimmed(text[lastFit!...]))
            }
        }

        let kept = lines.filter { !$0.isEmpty }
        return kept.isEmpty ? [text] : kept
    }

    static func withoutTrailingSpaces(_ text: Substring) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return text[..<end]
    }

    private static func trimmed(_ text: Substring) -> String {
        String(text).trimmingCharacters(in: .whitespaces)
    }
}

#endif
