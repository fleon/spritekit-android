#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// A font *handle* — a family name, a size and a weight.
///
/// Deliberately not a font engine. Its metrics come from whatever
/// `TextProvider` is registered with `TextMetrics`, which on Android is
/// HarfBuzz and FreeType in `Text/`. That keeps those two C libraries
/// out of this package, which everyone working on the scene graph, the
/// actions and the renderer has to build.
///
/// With no provider registered the metrics are zero, as they were before any
/// of this landed — an obvious nothing rather than plausible wrong numbers.
public final class UIFont: @unchecked Sendable {
    public struct Weight: Hashable, Sendable, RawRepresentable {
        public var rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }

        public static let ultraLight = Weight(rawValue: -0.8)
        public static let thin = Weight(rawValue: -0.6)
        public static let light = Weight(rawValue: -0.4)
        public static let regular = Weight(rawValue: 0)
        public static let medium = Weight(rawValue: 0.23)
        public static let semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4)
        public static let heavy = Weight(rawValue: 0.56)
        public static let black = Weight(rawValue: 0.62)
    }

    public let fontName: String
    public let pointSize: CGFloat
    public let weight: Weight

    public init?(name: String, size: CGFloat) {
        guard !name.isEmpty else { return nil }
        fontName = name
        pointSize = size
        weight = .regular
    }

    init(name: String, size: CGFloat, weight: Weight) {
        fontName = name
        pointSize = size
        self.weight = weight
    }

    public static func systemFont(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        UIFont(name: "system", size: size, weight: weight)
    }

    private var metrics: FontMetrics? {
        TextMetrics.provider?.fontMetrics(FontKey(name: fontName, size: pointSize))
    }

    /// `ascender − descender`, without the leading, as UIKit reports it
    /// (measured on the iOS simulator: Geneva 12 is 15.0 with a leading of
    /// 1.0), so a game's line-height constants keep the meaning they were
    /// tuned with.
    public var lineHeight: CGFloat { metrics.map { $0.ascent + $0.descent } ?? 0 }

    /// Positive above the baseline, as UIKit has it.
    public var ascender: CGFloat { metrics?.ascent ?? 0 }

    /// **Negative** below the baseline, as UIKit has it — FreeType reports
    /// descent the other way round, and the provider turns it over.
    public var descender: CGFloat { metrics.map { -$0.descent } ?? 0 }

    public var leading: CGFloat { metrics?.leading ?? 0 }
    public var capHeight: CGFloat { metrics?.capHeight ?? 0 }
    public var xHeight: CGFloat { metrics?.xHeight ?? 0 }

    /// The same measurement `SKLabelNode` lays out with, so a size taken
    /// here and a label's frame can never disagree.
    public func size(of text: String) -> CGSize {
        guard let provider = TextMetrics.provider else { return .zero }
        let line = provider.measure(text, font: FontKey(name: fontName, size: pointSize))
        return CGSize(width: line.advance, height: lineHeight)
    }
}

#endif
