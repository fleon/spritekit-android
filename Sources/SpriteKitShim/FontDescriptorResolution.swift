#if SPRITEKIT_SHIM
import Foundation

/// How a font descriptor's attributes pick one of the font catalog's faces,
/// as CoreText picks them (`UIFontDescriptor`). Kept apart from the
/// Android-only font types so it is host-tested on a Mac against CoreText
/// itself (`FontDescriptorParityTests`).
public enum FontDescriptorResolution {
    /// What a descriptor asks for, from its attributes.
    public struct Request: Sendable {
        /// `.name`: a PostScript name, or a family's.
        public var name: String?
        /// `.family`.
        public var family: String?
        /// `.face`, a style name ("Black").
        public var face: String?
        /// `.traits[.weight]`, UIKit's -1…1.
        public var weight: CGFloat?
        /// `.traits[.symbolic]`.
        public var symbolic: UInt32?
        /// The `wght` value of `kCTFontVariationAttribute`.
        public var variationWeight: Double?

        public init(
            name: String? = nil, family: String? = nil, face: String? = nil,
            weight: CGFloat? = nil, symbolic: UInt32? = nil, variationWeight: Double? = nil
        ) {
            self.name = name
            self.family = family
            self.face = face
            self.weight = weight
            self.symbolic = symbolic
            self.variationWeight = variationWeight
        }
    }

    /// `SymbolicTraits`' bits, as CoreText numbers them.
    static let italic: UInt32 = 1 << 0
    static let bold: UInt32 = 1 << 1
    static let expanded: UInt32 = 1 << 5
    static let condensed: UInt32 = 1 << 6
    static let vertical: UInt32 = 1 << 11
    /// The bits a face must have to be kept: bold, italic, the widths,
    /// monospace and the leadings. Vertical, UI-optimized and the class
    /// don't count.
    static let matched: UInt32 = italic | bold | expanded | condensed | 1 << 10 | 1 << 15 | 1 << 16

    /// The face `request` draws with; nil for the system font, which is
    /// where CoreText falls (to Helvetica) for a name or family it lacks, or
    /// for attributes no one face satisfies (a name with a family or style
    /// that isn't its own).
    public static func face(for request: Request, in catalog: FontCatalog) -> CatalogFace? {
        if let name = request.name {
            guard let face = catalog.face(named: name) else {
                // A family's name as the name stands for the family.
                guard request.family == nil, !catalog.faces(inFamily: name).isEmpty else { return nil }
                var family = request
                family.name = nil
                family.family = name
                return self.face(for: family, in: catalog)
            }
            if let family = request.family, !same(family, face.family) { return nil }
            if let style = request.face, !same(style, face.style) { return nil }
            // A variation sets the named face's own axis: another instance.
            if let wght = request.variationWeight, face.isInstance {
                let instances = catalog.faces(inFamily: face.family).filter { $0.isInstance && $0.isItalic == face.isItalic }
                return nearest(instances, toWeightClass: wght) ?? face
            }
            return face
        }
        guard let family = request.family else { return nil }
        let faces = catalog.faces(inFamily: family)
        guard !faces.isEmpty else { return nil }
        // Italic, asked for or not, among the faces that have it, if any do.
        let italic = (request.symbolic ?? 0) & Self.italic != 0
        let slanted = faces.filter { $0.isItalic == italic }
        let candidates = slanted.isEmpty ? faces : slanted
        // A variation beats the style, which beats the weight trait, which
        // beats the bold bit.
        if let wght = request.variationWeight, let face = nearest(candidates.filter(\.isInstance), toWeightClass: wght) {
            return face
        }
        if let style = request.face {
            if let face = faces.first(where: { same($0.style, style) }) { return face }
            // A style the family lacks is ignored, unless one of its words
            // is a weight no face of the family is ("Regular" of a family
            // of one Bold), which matches nothing.
            let lacking = style.split(separator: " ").contains { word in
                SystemFontFaces.styleWeights.contains { same($0.style, String(word)) }
                    && !faces.contains { same($0.style, String(word)) }
            }
            if lacking { return nil }
        }
        let weight = request.weight ?? ((request.symbolic ?? 0) & bold != 0 ? 0.4 : 0)
        return nearest(candidates, toTrait: weight)
    }

    /// How `withSymbolicTraits(_:)` changes a descriptor drawing a face.
    public enum TraitChange: Equatable, Sendable {
        /// The same descriptor: the face already has the traits.
        case unchanged
        /// The descriptor, named for this face.
        case face(CatalogFace)
        /// The descriptor's face at this `wght`: a variable font's way to
        /// answer a trait none of its instances has.
        case weight(Int)
    }

    /// `withSymbolicTraits(symbolic)` on a descriptor drawing `face`, as
    /// CoreText answers it; nil where no face fits.
    ///
    /// - A variable font's instance with exactly the traits asked (bold,
    ///   italic, widths, monospace, leadings) stays as it is: SemiBold
    ///   through Black with `.traitBold`, Thin through Medium with none.
    /// - Otherwise the family's face with the bold and italic asked whose
    ///   weight is nearest Bold's (0.4) for bold, else Regular's (0): Thin
    ///   through Medium with `.traitBold` become Bold, SemiBold and up with
    ///   none become Regular. A plain (static) face always goes this way.
    /// - With no such face, nil for a plain face; for an instance, the
    ///   instance at Regular's or Bold's `wght`, nil if that's itself: Light
    ///   with `.traitItalic` draws Regular, Regular with it is nil.
    public static func change(_ face: CatalogFace, to symbolic: UInt32, in catalog: FontCatalog) -> TraitChange? {
        if face.isInstance, symbolic & matched == symbolicTraits(of: face) { return .unchanged }
        let family = catalog.faces(inFamily: face.family)
        let bold = symbolic & Self.bold != 0
        let italic = symbolic & Self.italic != 0
        let target: CGFloat = bold ? 0.4 : 0
        // The catalog doesn't know widths: no face is condensed or expanded.
        if symbolic & (expanded | condensed) == 0 {
            let fitting = family.filter { $0.isBold == bold && $0.isItalic == italic }
            if let pick = nearest(fitting, toTrait: target) { return .face(pick) }
        }
        guard face.isInstance else { return nil }
        let instances = family.filter { $0.isInstance && $0.isItalic == face.isItalic }
        guard let fallback = nearest(instances, toTrait: target), fallback != face else { return nil }
        return .weight(bold ? 700 : 400)
    }

    /// `request` after `withSymbolicTraits(symbolic)`: renamed for the new
    /// face, or given its `wght`, as `UIFontDescriptor` changes its
    /// attributes; nil where no face fits.
    public static func request(_ request: Request, withSymbolicTraits symbolic: UInt32, in catalog: FontCatalog) -> Request? {
        guard let face = face(for: request, in: catalog),
              let change = change(face, to: symbolic, in: catalog)
        else { return nil }
        var changed = request
        if symbolic & vertical != 0 {
            // Vertical is kept in the traits, which it replaces.
            changed.weight = nil
            changed.symbolic = vertical
        }
        switch change {
        case .unchanged:
            break
        case .face(let face):
            changed.name = face.name
        case .weight(let wght):
            changed.name = face.name
            changed.variationWeight = Double(wght)
        }
        return changed
    }

    /// The face's bold and italic, as CoreText's symbolic traits.
    public static func symbolicTraits(of face: CatalogFace) -> UInt32 {
        (face.isBold ? bold : 0) | (face.isItalic ? italic : 0)
    }

    /// The face whose CoreText weight trait is nearest `weight`. CoreText
    /// keeps the traits as `Float`s and compares the request with them
    /// unrounded, so -0.5 is nearer ExtraLight's -0.4 than Thin's -0.6; on
    /// an exact tie the trait nearer 0 wins.
    static func nearest(_ faces: [CatalogFace], toTrait weight: CGFloat) -> CatalogFace? {
        SystemFontFaces.nearest(faces, to: Double(weight), weight: { Double($0.weightTrait) }) {
            abs($0.weightTrait) < abs($1.weightTrait)
        }
    }

    /// The instance whose `wght` is nearest. CoreText draws the weights
    /// between instances too; the text stack draws named instances only.
    static func nearest(_ faces: [CatalogFace], toWeightClass wght: Double) -> CatalogFace? {
        SystemFontFaces.nearest(faces, to: wght, weight: { Double($0.weightClass) }) { $0.weightClass < $1.weightClass }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}
#endif
