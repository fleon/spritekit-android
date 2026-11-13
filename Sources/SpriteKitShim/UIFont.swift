#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// A font *handle* — a family name, a size and a weight, nothing more.
///
/// Deliberately not a font engine. On Android the real work behind this is
/// FreeType for rasterising and HarfBuzz for shaping, which the game needs
/// for Thai (reordering, KoHo) and CJK, with the game's own `wrappedLines`
/// line breaking above it. Until that lands, this carries the description so
/// `appFont` / `chironFont` compile and the rest of the layer can be built
/// and tested; it measures nothing.
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

    /// Reported by the shaper once there is one; zero until then, which is the
    /// honest answer rather than a plausible wrong one.
    public var lineHeight: CGFloat { 0 }
    public var ascender: CGFloat { 0 }
    public var descender: CGFloat { 0 }
}

#endif
