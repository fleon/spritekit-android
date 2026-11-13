#if SPRITEKIT_SHIM
import Foundation

/// Line breaking and line bounds as CoreText reports them.
///
/// `Source/Utils/TextHelpers.swift` is pure CoreText — `wrappedLines` runs a
/// `CTTypesetter` and `capitalsOffset` reads a `CTLine`'s glyph-path bounds —
/// and it is the file the whole interface positions text with. This is what
/// stands behind those calls on Android.
///
/// It lives here rather than in `TextShaping` so it can be built and tested
/// on a Mac, and it reaches the shaper through `TextMetrics.provider` like
/// everything else in the layer, so it carries no C dependency of its own.
/// The `CT…` names themselves are in `CoreTextCompat.swift`, which is
/// Android-only because on Apple the real ones are right there.
public enum Typesetting {
    /// How many **UTF-16 units** from `start` fit in `maxWidth`, which is
    /// what `CTTypesetterSuggestLineBreak` returns and what the game then
    /// feeds to `NSString.substring(with:)`.
    ///
    /// A hard line break ends the line there whatever the width, as
    /// CoreText's does. A word wider than the line is left whole rather than
    /// cut, which is `LineBreak`'s rule — CoreText would cut it, and the
    /// difference only shows on a word that cannot fit at all.
    public static func suggestLineBreak(
        _ text: String,
        font: FontKey,
        startingAt start: Int,
        maxWidth: CGFloat
    ) -> Int {
        guard let provider = TextMetrics.provider else { return 0 }
        guard start >= 0, start < text.utf16.count else { return 0 }

        let begin = String.Index(utf16Offset: start, in: text)
        var tail = String(text[begin...])
        if let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[..<tail.index(after: newline)])
        }
        guard !tail.isEmpty else { return 0 }

        let whole = tail.utf16.count
        func width(upTo offset: Int) -> CGFloat {
            let end = String.Index(utf16Offset: offset, in: tail)
            return provider.measure(String(tail[..<end]), font: font).advance
        }

        if maxWidth <= 0 || width(upTo: whole) <= maxWidth { return whole }

        let places = provider.breakOffsets(in: tail)
        var best = 0
        for place in places {
            guard width(upTo: place) <= maxWidth else { break }
            best = place
        }
        // Never zero: CoreText always advances, and so must the loop in
        // `wrappedLines` that calls this.
        if best > 0 { return best }
        return places.first ?? whole
    }

    /// The box the ink of a line covers, measured from the pen's origin on
    /// the baseline — `CTLineGetBoundsWithOptions(_:.useGlyphPathBounds)`.
    public static func lineBounds(_ text: String, font: FontKey, glyphPath: Bool) -> CGRect {
        guard let provider = TextMetrics.provider else { return .zero }
        let line = provider.measure(text, font: font)
        guard glyphPath else {
            // The typographic box: the whole line's advance, from descender
            // to ascender, which is what CoreText reports without the option.
            guard let metrics = provider.fontMetrics(font) else { return .zero }
            return CGRect(
                x: 0,
                y: -metrics.descent,
                width: line.advance,
                height: metrics.ascent + metrics.descent
            )
        }
        return line.inkBounds
    }
}

#endif
