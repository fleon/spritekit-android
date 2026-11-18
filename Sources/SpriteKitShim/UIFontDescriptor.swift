#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

/// CoreText's key for a variable font's axis values, `[axis tag: value]`.
public let kCTFontVariationAttribute: CFString = "NSCTFontVariationAttribute"

/// UIKit's font descriptor: attributes that name a face, resolved to one of
/// the faces the font catalog holds (`TextMetrics.catalog`: each registered
/// face's family, style, weight and slant), as CoreText resolves them
/// (`FontDescriptorResolution`, pinned against CoreText on a Mac by
/// `FontDescriptorParityTests`):
///   - `.name` wins outright, in any case; a family's name stands for the
///     family; a `.family` or `.face` that isn't the face's own matches
///     nothing, which is the system font;
///   - else `.family`'s faces: the one `.face` names, else the named
///     instance nearest a variation's `wght` value, else the face whose
///     CoreText weight trait is nearest the weight trait, or the bold bit's
///     0.4 (Montserrat: `.light` is ExtraLight, `.heavy` and `.black`
///     ExtraBold), italic or not as `.traits[.symbolic]` asks where the
///     family has both;
///   - a name or family the catalog lacks, or neither, is the system font.
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

    public struct SymbolicTraits: OptionSet, Hashable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let traitItalic = SymbolicTraits(rawValue: 1 << 0)
        public static let traitBold = SymbolicTraits(rawValue: 1 << 1)
        public static let traitExpanded = SymbolicTraits(rawValue: 1 << 5)
        public static let traitCondensed = SymbolicTraits(rawValue: 1 << 6)
        public static let traitMonoSpace = SymbolicTraits(rawValue: 1 << 10)
        public static let traitVertical = SymbolicTraits(rawValue: 1 << 11)
        public static let traitUIOptimized = SymbolicTraits(rawValue: 1 << 12)
        public static let traitTightLeading = SymbolicTraits(rawValue: 1 << 15)
        public static let traitLooseLeading = SymbolicTraits(rawValue: 1 << 16)
        public static let classMask = SymbolicTraits(rawValue: 0xF000_0000)
        public static let classOldStyleSerifs = SymbolicTraits(rawValue: 1 << 28)
        public static let classTransitionalSerifs = SymbolicTraits(rawValue: 2 << 28)
        public static let classModernSerifs = SymbolicTraits(rawValue: 3 << 28)
        public static let classClarendonSerifs = SymbolicTraits(rawValue: 4 << 28)
        public static let classSlabSerifs = SymbolicTraits(rawValue: 5 << 28)
        public static let classFreeformSerifs = SymbolicTraits(rawValue: 7 << 28)
        public static let classSansSerif = SymbolicTraits(rawValue: 8 << 28)
        public static let classOrnamentals = SymbolicTraits(rawValue: 9 << 28)
        public static let classScripts = SymbolicTraits(rawValue: 10 << 28)
        public static let classSymbolic = SymbolicTraits(rawValue: 12 << 28)
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

    /// `.size` as any number type (an `Int` 20 is 20, as on UIKit); 0
    /// without one.
    public var pointSize: CGFloat {
        Self.number(fontAttributes[.size]) ?? 0
    }

    public var postscriptName: String { resolvedName }

    /// The resolved face's bold and italic (CoreText's class bits aren't
    /// kept); for a name or family the catalog lacks, the bits asked for,
    /// as UIKit reports them.
    public var symbolicTraits: SymbolicTraits {
        if let face = resolvedFace {
            return SymbolicTraits(rawValue: FontDescriptorResolution.symbolicTraits(of: face))
        }
        if let symbolic = request.symbolic { return SymbolicTraits(rawValue: symbolic) }
        let system = UIFont.systemFont(ofSize: 1, weight: UIFont.Weight(rawValue: traitWeight ?? 0))
        return system.weight.rawValue >= UIFont.Weight.semibold.rawValue ? .traitBold : []
    }

    public func addingAttributes(_ attributes: [AttributeName: Any]) -> UIFontDescriptor {
        UIFontDescriptor(fontAttributes: fontAttributes.merging(attributes) { _, new in new })
    }

    public func withSize(_ newPointSize: CGFloat) -> UIFontDescriptor {
        addingAttributes([.size: newPointSize])
    }

    /// The face of the same family with exactly these traits, as CoreText
    /// finds it (`FontDescriptorResolution.change`); nil where the family
    /// has none (`.traitItalic` on a family with no italic). Only bold
    /// counts for the system font, as UIKit's: `.traitBold` makes Regular
    /// Bold and keeps every other weight, and without it SemiBold and up
    /// become Regular. The device's system faces are upright, so italic is
    /// dropped.
    public func withSymbolicTraits(_ symbolicTraits: SymbolicTraits) -> UIFontDescriptor? {
        let bold = symbolicTraits.contains(.traitBold)
        if UIFont.isSystemFace(resolvedName) {
            let weight = UIFont.Weight(rawValue: traitWeight ?? 0)
            let isBold = weight.rawValue >= UIFont.Weight.semibold.rawValue
            let kept: UIFont.Weight = bold
                ? (weight == .regular ? .bold : weight)
                : (isBold ? .regular : weight)
            let font = UIFont.systemFont(ofSize: max(pointSize, 1), weight: kept)
            return addingAttributes([.name: font.fontName, .traits: [TraitKey.weight: kept]])
        }
        guard let catalog = TextMetrics.catalog else {
            // With no catalog (a host test), only the traits are recorded.
            return addingAttributes([.traits: [TraitKey.symbolic: symbolicTraits.rawValue]])
        }
        guard let face = resolvedFace,
              let change = FontDescriptorResolution.change(face, to: symbolicTraits.rawValue, in: catalog)
        else { return nil }
        // Vertical is kept in the traits, which it replaces.
        let base = symbolicTraits.contains(.traitVertical)
            ? addingAttributes([.traits: [TraitKey.symbolic: SymbolicTraits.traitVertical.rawValue]])
            : self
        switch change {
        case .unchanged:
            return base
        case .face(let face):
            return base.addingAttributes([.name: face.name])
        case .weight(let wght):
            return base.addingAttributes([
                .name: face.name,
                AttributeName(kCTFontVariationAttribute): [NSNumber(value: Self.weightAxis): NSNumber(value: wght)],
            ])
        }
    }

    /// The same face in one of the system designs. Android draws the system
    /// font for every design, so only the system font has the designs, as on
    /// Apple, where a custom face has none and this is nil.
    public func withDesign(_ design: SystemDesign) -> UIFontDescriptor? {
        guard UIFont.isSystemFace(resolvedName) else { return nil }
        return self
    }

    /// The attributes `FontDescriptorResolution` resolves.
    var request: FontDescriptorResolution.Request {
        let traits = fontAttributes[.traits] as? [TraitKey: Any]
        return FontDescriptorResolution.Request(
            name: fontAttributes[.name] as? String,
            family: fontAttributes[.family] as? String,
            face: fontAttributes[.face] as? String,
            weight: traitWeight,
            symbolic: Self.number(traits?[.symbolic]).map { UInt32(truncatingIfNeeded: Int64($0)) },
            variationWeight: variationWeight
        )
    }

    /// The catalog's face for this descriptor; nil for the system font, or
    /// where there is no catalog.
    var resolvedFace: CatalogFace? {
        TextMetrics.catalog.flatMap { FontDescriptorResolution.face(for: request, in: $0) }
    }

    /// The registered name this descriptor draws with.
    var resolvedName: String {
        if let face = resolvedFace { return face.name }
        if TextMetrics.catalog == nil {
            // With no catalog (a host test), the name or family, unchecked.
            if let name = (fontAttributes[.name] ?? fontAttributes[.family]) as? String { return name }
        }
        return UIFont.systemFont(ofSize: max(pointSize, 1), weight: UIFont.Weight(rawValue: traitWeight ?? 0)).fontName
    }

    /// The trait's weight, as UIKit's `UIFont.Weight` scale.
    var traitWeight: CGFloat? {
        guard let traits = fontAttributes[.traits] as? [TraitKey: Any] else { return nil }
        if let weight = traits[.weight] as? UIFont.Weight { return weight.rawValue }
        return Self.number(traits[.weight])
    }

    /// The variation's `wght` value, by any of the ways a tag can be keyed.
    var variationWeight: Double? {
        let variation = fontAttributes[AttributeName(kCTFontVariationAttribute)]
        if let dictionary = variation as? [NSNumber: Any] {
            return Self.number(dictionary[NSNumber(value: Self.weightAxis)]).map(Double.init)
        }
        if let dictionary = variation as? [Int: Any] {
            return Self.number(dictionary[Self.weightAxis]).map(Double.init)
        }
        return nil
    }

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat: return value
        case let value as Double: return CGFloat(value)
        case let value as Float: return CGFloat(value)
        case let value as Int: return CGFloat(value)
        case let value as UInt32: return CGFloat(value)
        case let value as NSNumber: return CGFloat(value.doubleValue)
        default: return nil
        }
    }
}

extension UIFont {
    /// Whether `name` is the system font: one of the device's own faces, or
    /// "system" where the stack has none.
    static func isSystemFace(_ name: String) -> Bool {
        name == "system" || (TextMetrics.catalog?.systemFaceNames.contains(name) ?? false)
    }

    /// A font from a descriptor: `size`, else the descriptor's, else 12,
    /// as UIKit falls back.
    public convenience init(descriptor: UIFontDescriptor, size pointSize: CGFloat) {
        let size = pointSize > 0 ? pointSize : descriptor.pointSize > 0 ? descriptor.pointSize : 12
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

    /// The face's family as the catalog has it (FreeType's family name,
    /// which needn't be the PostScript name's prefix), else the name itself.
    public var familyName: String {
        TextMetrics.catalog?.face(named: fontName)?.family ?? fontName
    }
}
#endif
