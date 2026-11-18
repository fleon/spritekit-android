#if canImport(CoreText) && os(macOS)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

// How a font descriptor's attributes pick a face (`FontDescriptorResolution`,
// behind Android's `UIFontDescriptor`), against Core Text's own answer for
// the same attributes on the same files: Montserrat, a variable font with
// named instances Thin to Black, and KoHo Bold, a plain face alone in its
// family. Core Text's descriptors answer as UIKit's do (`UIFontDescriptor`
// and `withSymbolicTraits(_:)` on Mac Catalyst give the same faces for every
// case here).

typealias DescriptorRequest = FontDescriptorResolution.Request

@Suite("Font descriptors as Core Text resolves them", .serialized)
struct FontDescriptorParityTests {
    /// The fixtures alone, so a family holds only its own files.
    static let catalog: TextEngine = {
        let library = FontLibrary()
        for file in ["Montserrat", "KoHo-Bold"] {
            _ = try? library.register(path: Fonts.directory + "/" + file + ".ttf")
        }
        return TextEngine(library: library, atlas: GlyphAtlas(library: library))
    }()

    static let instances = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]
        .map { "Montserrat-\($0)" }
    static let faces = instances + ["KoHo-Bold"]

    /// The face Core Text draws `request` with, after `symbolic` if given:
    /// nil for none (`withSymbolicTraits` found none) and "system" for its
    /// fallback face, Helvetica.
    static func coreText(_ request: DescriptorRequest, symbolic: UInt32? = nil) -> String? {
        _ = CoreTextParityTests.registered
        // A size, as `UIFontDescriptor(name:size:)` and `UIFont.fontDescriptor`
        // give every descriptor they make: without one, Core Text resolves
        // a name's copy with a trait no instance has (`.traitItalic`) to the
        // instance itself instead of Regular's or Bold's `wght`.
        var attributes: [String: Any] = [kCTFontSizeAttribute as String: 12]
        var traits: [String: Any] = [:]
        if let name = request.name { attributes[kCTFontNameAttribute as String] = name }
        if let family = request.family { attributes[kCTFontFamilyNameAttribute as String] = family }
        if let face = request.face { attributes[kCTFontStyleNameAttribute as String] = face }
        if let weight = request.weight { traits[kCTFontWeightTrait as String] = weight }
        if let bits = request.symbolic { traits[kCTFontSymbolicTrait as String] = bits }
        if !traits.isEmpty { attributes[kCTFontTraitsAttribute as String] = traits }
        if let wght = request.variationWeight {
            attributes[kCTFontVariationAttribute as String] = [0x7767_6874: wght]
        }
        var descriptor: CTFontDescriptor? = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        if let symbolic, let base = descriptor {
            descriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
                base, CTFontSymbolicTraits(rawValue: symbolic), CTFontSymbolicTraits(rawValue: .max)
            )
        }
        guard let descriptor else { return nil }
        let name = CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor(descriptor, 0, nil)) as String
        return name == "Helvetica" ? "system" : name
    }

    /// The face the shim draws `request` with, the same way round.
    static func shim(_ request: DescriptorRequest, symbolic: UInt32? = nil) -> String? {
        var request = request
        if let symbolic {
            guard let changed = FontDescriptorResolution.request(request, withSymbolicTraits: symbolic, in: catalog) else {
                return nil
            }
            request = changed
        }
        return FontDescriptorResolution.face(for: request, in: catalog)?.name ?? "system"
    }

    static func expectSame(_ request: DescriptorRequest, symbolic: UInt32? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let theirs = coreText(request, symbolic: symbolic)
        let ours = shim(request, symbolic: symbolic)
        #expect(ours == theirs, "\(request) + \(symbolic.map { String($0, radix: 16) } ?? "-")", sourceLocation: sourceLocation)
    }

    @Test("Each face's weight trait is Core Text's, to the bit, and bold from SemiBold up")
    func weightTraits() throws {
        _ = CoreTextParityTests.registered
        for name in Self.faces {
            let face = try #require(Self.catalog.face(named: name))
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let traits = CTFontCopyTraits(font) as NSDictionary
            let theirs = try #require(traits[kCTFontWeightTrait] as? NSNumber).doubleValue
            #expect(Double(face.weightTrait) == theirs, "\(name)")
            let symbolic = CTFontGetSymbolicTraits(font).rawValue & 0b11
            #expect(FontDescriptorResolution.symbolicTraits(of: face) == symbolic, "\(name)")
            #expect(face.family == CTFontCopyFamilyName(font) as String, "\(name)")
        }
    }

    @Test("A weight trait picks the face whose trait is nearest, to the boundary", arguments: ["Montserrat", "KoHo", "montserrat"])
    func weights(family: String) {
        var weights = stride(from: -1.0, through: 1.0, by: 0.01).map { $0 }
        weights += [-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62, -5, 5]
        // Either side of, and on, each midpoint between neighbouring
        // instances' traits, which Core Text keeps as Floats.
        let traits: [Float] = [-0.6, -0.4, -0.23, 0, 0.2, 0.3, 0.4, 0.6, 0.8]
        for (a, b) in zip(traits, traits.dropFirst()) {
            let middle = (Double(a) + Double(b)) / 2
            weights += [middle.nextDown, middle, middle.nextUp, Double(Float(middle))]
        }
        for weight in weights {
            Self.expectSame(DescriptorRequest(family: family, weight: CGFloat(weight)))
        }
    }

    @Test("A wght variation picks its instance, ahead of the weight trait and the bold bit")
    func variations() {
        // Beyond the axis, a family clamps to its ends.
        for wght in [50.0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000] {
            Self.expectSame(DescriptorRequest(family: "Montserrat", variationWeight: wght))
            Self.expectSame(DescriptorRequest(family: "Montserrat", weight: -0.4, variationWeight: wght))
            Self.expectSame(DescriptorRequest(family: "Montserrat", symbolic: 2, variationWeight: wght))
            Self.expectSame(DescriptorRequest(family: "Montserrat", face: "Black", variationWeight: wght))
            Self.expectSame(DescriptorRequest(name: "KoHo-Bold", variationWeight: wght))
        }
        for wght in [100.0, 200, 300, 400, 500, 600, 700, 800, 900] {
            Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", variationWeight: wght))
            Self.expectSame(DescriptorRequest(name: "Montserrat-Black", variationWeight: wght))
        }
    }

    @Test("The symbolic trait: bold where no weight is given, italic only where the family has it")
    func symbolic() {
        for family in ["Montserrat", "KoHo"] {
            for bits: UInt32 in [0, 1, 2, 3, 0x400, 0x402, 0x20, 0x40] {
                Self.expectSame(DescriptorRequest(family: family, symbolic: bits))
                Self.expectSame(DescriptorRequest(family: family, weight: -0.4, symbolic: bits))
                Self.expectSame(DescriptorRequest(family: family, weight: 0.23, symbolic: bits))
            }
        }
    }

    @Test("A face (style) name wins over the traits; one the family lacks is ignored")
    func styles() {
        for style in ["Black", "black", "BOLD", "Thin", "SemiBold", "Regular", "Nonsense", "Montserrat Black"] {
            Self.expectSame(DescriptorRequest(family: "Montserrat", face: style))
            Self.expectSame(DescriptorRequest(family: "Montserrat", face: style, weight: 0.4))
            Self.expectSame(DescriptorRequest(family: "Montserrat", face: style, symbolic: 2))
        }
        for style in ["Bold", "Regular", "Black", "Italic", "Bold Italic", "Nonsense"] {
            Self.expectSame(DescriptorRequest(family: "KoHo", face: style))
            Self.expectSame(DescriptorRequest(family: "KoHo", face: style, weight: -0.6))
        }
    }

    @Test("A name wins, in any case; with another family or style it matches nothing")
    func names() {
        for name in Self.faces + ["montserrat-black", "KOHO-BOLD", "Montserrat", "KoHo", "NoSuch-Face"] {
            Self.expectSame(DescriptorRequest(name: name))
            Self.expectSame(DescriptorRequest(name: name, weight: 0.4))
            Self.expectSame(DescriptorRequest(name: name, symbolic: 2))
        }
        Self.expectSame(DescriptorRequest(name: "Montserrat", weight: 0.4))
        Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", family: "Montserrat"))
        Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", family: "montserrat"))
        Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", family: "KoHo"))
        Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", face: "Thin"))
        Self.expectSame(DescriptorRequest(name: "Montserrat-Thin", face: "Bold"))
        Self.expectSame(DescriptorRequest(family: "No Such Family"))
    }

    @Test("withSymbolicTraits: the face with exactly those traits, or none")
    func withSymbolicTraits() {
        // [], bold, italic, bold-italic, expanded, condensed, monospace,
        // vertical, UI-optimized, tight and loose leading, bold monospace.
        let sets: [UInt32] = [0, 2, 1, 3, 0x20, 0x40, 0x400, 0x800, 0x1000, 0x8000, 0x10000, 0x402]
        var requests = Self.faces.map { DescriptorRequest(name: $0) }
        requests += ["Montserrat", "KoHo"].map { DescriptorRequest(family: $0) }
        requests += [-0.4, 0.23, 0.3, 0.62].map { DescriptorRequest(family: "Montserrat", weight: $0) }
        requests += [
            DescriptorRequest(name: "Montserrat"),
            DescriptorRequest(name: "NoSuch-Face"),
            DescriptorRequest(family: "Montserrat", face: "Black"),
            DescriptorRequest(family: "Montserrat", variationWeight: 300),
        ]
        for request in requests {
            for bits in sets {
                Self.expectSame(request, symbolic: bits)
            }
        }
    }

    @Test("Chained: bold, then none, comes back to Regular")
    func chained() throws {
        let bold = try #require(FontDescriptorResolution.request(DescriptorRequest(name: "Montserrat-Thin"), withSymbolicTraits: 2, in: Self.catalog))
        #expect(Self.shim(bold) == "Montserrat-Bold")
        #expect(Self.shim(bold, symbolic: 0) == "Montserrat-Regular")
    }
}
#endif
