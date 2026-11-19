#if canImport(CTextShaping)
import Foundation

/// Where a line may break in Thai text, from the platform's dictionary:
/// Thai is written without spaces between words, so breaking it needs one.
/// Core Text breaks it with ICU's line-break iterator; Android carries ICU
/// too (`java.text.BreakIterator.getLineInstance`), which the shell installs
/// here, and a test on the Mac installs CoreFoundation's tokenizer
/// (`kCFStringTokenizerUnitLineBreak`), which is ICU's. With no provider,
/// `LineBreak` falls back to grapheme clusters.
public enum ThaiLineBreaks {
    /// The UTF-16 offsets in a run of Thai text where a line may start (0
    /// may be left out); nil when the platform can't say, which keeps the
    /// fallback for that text.
    public nonisolated(unsafe) static var provider: ((String) -> [Int]?)? {
        didSet { lock.withLock { cache.removeAll() } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Int]?] = [:]
    private static let cacheLimit = 256

    /// Every index in `text` where a line may start between two Thai
    /// characters; nil with no provider.
    static func lineStarts(in text: String) -> Set<String.Index>? {
        guard let provider else { return nil }
        guard text.contains(where: LineBreak.isThai) else { return [] }
        var starts: Set<String.Index> = []
        var index = text.startIndex
        while index < text.endIndex {
            guard LineBreak.isThai(text[index]) else {
                index = text.index(after: index)
                continue
            }
            // A run of Thai, asked about whole.
            var end = index
            while end < text.endIndex, LineBreak.isThai(text[end]) { end = text.index(after: end) }
            let run = String(text[index ..< end])
            let known: [Int]?? = lock.withLock { cache[run] }
            let answer: [Int]? = known ?? {
                let found = provider(run)
                lock.withLock {
                    if cache.count >= cacheLimit { cache.removeAll() }
                    cache[run] = found
                }
                return found
            }()
            guard let offsets = answer else { return nil }
            let utf16 = run.utf16
            for offset in offsets where offset > 0 && offset < utf16.count {
                let position = utf16.index(utf16.startIndex, offsetBy: offset)
                if let start = position.samePosition(in: run) {
                    starts.insert(text.index(index, offsetBy: run.distance(from: run.startIndex, to: start)))
                }
            }
            index = end
        }
        return starts
    }
}
#endif
