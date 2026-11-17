#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// CoreText's key for a variable font's axis values, `[axis tag: value]`.
public let kCTFontVariationAttribute: CFString = "NSCTFontVariationAttribute"

/// UIKit's font descriptor: attributes that name a face, resolved to one of
/// the faces the font catalog holds (`TextMetrics.catalog`: each registered
/// face's family, PostScript name and named instances).
///
/// Resolution, measured against CoreText on a Mac with the games' own
/// variable fonts (`FontDescriptorTests` pins it):
///   - `.name` wins outright;
///   - else `.family` with a variation's `wght` value takes the named
///     instance at that weight ("Family" + 900 is "Family-Black"), whatever
///     the weight trait says;
///   - else `.family` with the weight trait takes the instance CoreText
///     matches it to: regular 400, medium 500, semibold 600, bold 700, and
///     heavy and black both 800 ("Family-ExtraBold");
///   - the instance is named `<family>-<style>` (Thin … Black), as variable
///     fonts name theirs; where the text stack doesn't know that name, the
///     nearest registered weight, then the family itself.
public final class UIFontDescriptor: @unchecked Sendable {
    public struct AttributeName: Hashable, RawRepresentable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public static let family = AttributeName("NSFontFamilyAttribute")
        public static let name = AttributeName("NSFontNameAttribute")
        public static let face = AttributeName("NSFontFaceAttribute")
        public static let size = AttributeName("NSFontSizeAttribute")
        public static let visibleName = AttributeName("NSFontVisibleNameAttribute")
        public static let traits = AttributeName("NSCTFontTraitsAttribute")
    }

    public struct TraitKey: Hashable, RawRepresentable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public static let symbolic = TraitKey("NSCTFontSymbolicTrait")
        public static let weight = TraitKey("NSCTFontWeightTrait")
        public static let width = TraitKey("NSCTFontProportionTrait")
        public static let slant = TraitKey("NSCTFontSlantTrait")
    }

    public struct SystemDesign: Hashable, RawRepresentable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let `default` = SystemDesign(rawValue: "NSCTFontUIFontDesignDefault")
        public static let rounded = SystemDesign(rawValue: "NSCTFontUIFontDesignRounded")
        public static let serif = SystemDesign(rawValue: "NSCTFontUIFontDesignSerif")
        public static let monospaced = SystemDesign(rawValue: "NSCTFontUIFontDesignMonospaced")
    }

    /// OpenType's `wght` axis tag, as the variation dictionary keys it.
    static let weightAxis = 0x7767_6874

    public let fontAttributes: [AttributeName: Any]

    public init(fontAttributes attributes: [AttributeName: Any] = [:]) {
        fontAttributes = attributes
    }

    public convenience init(name fontName: String, size: CGFloat) {
        self.init(fontAttributes: [.name: fontName, .size: size])
    }

    public var pointSize: CGFloat {
        (fontAttributes[.size] as? CGFloat) ?? (fontAttributes[.size] as? Double).map { CGFloat($0) } ?? 0
    }

    public var postscriptName: String { resolvedName }

    public func addingAttributes(_ attributes: [AttributeName: Any]) -> UIFontDescriptor {
        UIFontDescriptor(fontAttributes: fontAttributes.merging(attributes) { _, new in new })
    }

    public func withSize(_ newPointSize: CGFloat) -> UIFontDescriptor {
        addingAttributes([.size: newPointSize])
    }

    /// The same face in one of the system designs. Android draws the system
    /// font for every design, so only the system font has the designs, as on
    /// Apple, where a custom face has none and this is nil.
    public func withDesign(_ design: SystemDesign) -> UIFontDescriptor? {
        guard UIFont.isSystemFace(resolvedName) else { return nil }
        return self
    }

    /// The registered name this descriptor draws with.
    var resolvedName: String {
        if let name = fontAttributes[.name] as? String { return name }
        guard let family = fontAttributes[.family] as? String else {
            return UIFont.systemFont(ofSize: max(pointSize, 1), weight: UIFont.Weight(rawValue: traitWeight ?? 0)).fontName
        }
        let weight = variationWeight ?? FontDescriptorResolution.openTypeWeight(for: traitWeight ?? 0)
        return FontDescriptorResolution.name(family: family, weight: weight) { name in
            // With no catalog (a host test), the exact name, unchecked.
            TextMetrics.catalog?.hasFace(named: name) ?? true
        }
    }

    /// The trait's weight, as UIKit's `UIFont.Weight` scale.
    var traitWeight: CGFloat? {
        guard let traits = fontAttributes[.traits] as? [TraitKey: Any] else { return nil }
        let value = traits[.weight]
        if let weight = value as? UIFont.Weight { return weight.rawValue }
        if let weight = value as? CGFloat { return weight }
        if let weight = value as? Double { return CGFloat(weight) }
        return nil
    }

    /// The variation's `wght` value, by any of the ways a tag can be keyed.
    var variationWeight: Int? {
        let variation = fontAttributes[AttributeName(kCTFontVariationAttribute)]
        func number(_ value: Any?) -> Int? {
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value.rounded()) }
            if let value = value as? CGFloat { return Int(value.rounded()) }
            return nil
        }
        if let dictionary = variation as? [NSNumber: Any] {
            return number(dictionary[NSNumber(value: Self.weightAxis)])
        }
        if let dictionary = variation as? [Int: Any] {
            return number(dictionary[Self.weightAxis])
        }
        return nil
    }
}

extension UIFont {
    /// Whether `name` is the system font: one of the device's own faces, or
    /// "system" where the stack has none.
    static func isSystemFace(_ name: String) -> Bool {
        name == "system" || (TextMetrics.catalog?.systemFaceNames.contains(name) ?? false)
    }

    /// A font from a descriptor; `size` 0 keeps the descriptor's own.
    public convenience init(descriptor: UIFontDescriptor, size pointSize: CGFloat) {
        let size = pointSize > 0 ? pointSize : descriptor.pointSize
        let name = descriptor.resolvedName
        let weight = descriptor.traitWeight.map { UIFont.Weight(rawValue: $0) } ?? .regular
        self.init(name: name, size: size, weight: weight)
    }

    public var fontDescriptor: UIFontDescriptor {
        var attributes: [UIFontDescriptor.AttributeName: Any] = [.name: fontName, .size: pointSize]
        if UIFont.isSystemFace(fontName) {
            attributes[.traits] = [UIFontDescriptor.TraitKey.weight: weight]
        }
        return UIFontDescriptor(fontAttributes: attributes)
    }

    public var familyName: String {
        guard fontName != "system", let dash = fontName.lastIndex(of: "-") else { return fontName }
        return String(fontName[..<dash])
    }
}
#endif
