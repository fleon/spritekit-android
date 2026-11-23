import Foundation
import SpriteKitShim

/// Which way the interface reads: left to right, or right to left (Arabic,
/// Hebrew, Persian, Urdu). Layout written with leading and trailing edges
/// (`LayoutItem`, `SceneLayout`'s edge helpers) mirrors by it; what shows
/// a physical direction (a board, a slider's track, a clock) stays as drawn.
public nonisolated enum LayoutDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft

    /// The direction the game's language reads in, unless `forced`.
    public static var current: LayoutDirection {
        forced ?? resolve()
    }

    /// The direction of the game's language: set by `Typography.follow`, or
    /// by a game that resolves its language another way.
    public nonisolated(unsafe) static var resolve: () -> LayoutDirection = { .leftToRight }

    /// A direction every layout takes whatever the language (a debug launch
    /// argument mirroring the interface in English, say); nil follows it.
    public nonisolated(unsafe) static var forced: LayoutDirection?

    /// Languages whose script reads right to left, by language code.
    private static let rightToLeftLanguages: Set<String> = ["ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "ku-Arab", "ps", "sd", "ug", "ur", "yi"]

    /// The direction a language code (`"ar"`, `"he-IL"`, `"pt-BR"`) reads in.
    public static func of(language code: String) -> LayoutDirection {
        let parts = code.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let language = parts.first.map({ $0.lowercased() }) else { return .leftToRight }
        if rightToLeftLanguages.contains(language) { return .rightToLeft }
        if let script = parts.dropFirst().first, rightToLeftLanguages.contains("\(language)-\(script)") { return .rightToLeft }
        return .leftToRight
    }

    public var isRightToLeft: Bool { self == .rightToLeft }

    /// The screen side an edge is on: -1 left, 1 right, as `SceneLayout`'s
    /// `side` arguments take it.
    public func side(_ edge: HorizontalEdge) -> CGFloat {
        let leadingSide: CGFloat = isRightToLeft ? 1 : -1
        return edge == .leading ? leadingSide : -leadingSide
    }

    /// The x of `rect`'s `edge`.
    public func x(_ edge: HorizontalEdge, of rect: CGRect) -> CGFloat {
        side(edge) < 0 ? rect.minX : rect.maxX
    }

    /// An `xScale` sign that turns art drawn for left to right (a back
    /// chevron, a "next" arrow) to face this direction.
    public var mirrorScale: CGFloat { isRightToLeft ? -1 : 1 }

    /// A label's alignment for text set against `edge`.
    public func labelAlignment(_ edge: HorizontalEdge) -> SKLabelHorizontalAlignmentMode {
        side(edge) < 0 ? .left : .right
    }
}

/// A horizontal edge named by reading order: leading is where lines start
/// (the left in English, the right in Arabic).
public nonisolated enum HorizontalEdge: Sendable, Equatable {
    case leading
    case trailing
}

extension LocalizationLanguage {
    /// The direction this language reads in, from its raw value as a
    /// language code.
    public var layoutDirection: LayoutDirection { LayoutDirection.of(language: rawValue) }
}
