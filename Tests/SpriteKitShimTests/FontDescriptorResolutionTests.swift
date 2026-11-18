import Foundation
import Testing
@testable import SpriteKitShim

// The catalog side of font descriptors: a family is found by the family name
// its files carry, not by building "<family>-<Style>" names, which don't
// exist where the PostScript names' prefix is another spelling of the
// family. Resolution itself is pinned against Core Text in Text's
// `FontDescriptorParityTests`.

private final class Catalog: FontCatalog, @unchecked Sendable {
    let faces: [CatalogFace]
    init(_ faces: [CatalogFace]) { self.faces = faces }

    func faceNames(inFontAt path: String) -> [String]? { nil }
    func registerFont(at path: String) -> FontRegistration { .unreadable }
    func hasFace(named name: String) -> Bool { face(named: name) != nil }
    var systemFaceNames: [String] { [] }
    func face(named name: String) -> CatalogFace? {
        faces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    func faces(inFamily family: String) -> [CatalogFace] {
        faces.filter { $0.family.caseInsensitiveCompare(family) == .orderedSame }
    }
}

/// Three plain faces of one family, named without its spaces.
private let catalog = Catalog([
    CatalogFace(name: "SampleSans-Regular", family: "Sample Sans", style: "Regular", weightClass: 400, isItalic: false, isInstance: false),
    CatalogFace(name: "SampleSans-Bold", family: "Sample Sans", style: "Bold", weightClass: 700, isItalic: false, isInstance: false),
    CatalogFace(name: "SampleSans-Italic", family: "Sample Sans", style: "Italic", weightClass: 400, isItalic: true, isInstance: false),
])

@Suite("Font descriptor resolution")
struct FontDescriptorResolutionTests {
    @Test("CoreText's weight trait for each weight class, straight between the hundreds")
    func faceTraits() {
        let traits = [50, 100, 200, 225, 300, 400, 500, 525, 600, 700, 725, 800, 900, 1000]
            .map { Double(SystemFontFaces.faceTrait(forWeightClass: $0)) }
        let measured: [Float] = [-0.6, -0.6, -0.4, -0.3575, -0.23, 0, 0.2, 0.225, 0.3, 0.4, 0.45, 0.6, 0.8, 0.8]
        for (ours, theirs) in zip(traits, measured) {
            #expect(abs(ours - Double(theirs)) < 1e-6)
        }
        // The hundreds exactly as CoreText stores them, as Floats.
        #expect(SystemFontFaces.faceTrait(forWeightClass: 300) == CGFloat(Float(-0.23)))
    }

    @Test("A family is its files' family name, whatever their PostScript names")
    func family() {
        let resolve = { FontDescriptorResolution.face(for: $0, in: catalog)?.name }
        #expect(resolve(.init(family: "Sample Sans")) == "SampleSans-Regular")
        #expect(resolve(.init(family: "Sample Sans", weight: 0.4)) == "SampleSans-Bold")
        #expect(resolve(.init(family: "Sample Sans", symbolic: 2)) == "SampleSans-Bold")
        #expect(resolve(.init(family: "Sample Sans", symbolic: 1)) == "SampleSans-Italic")
        #expect(resolve(.init(family: "Sample Sans", face: "Bold")) == "SampleSans-Bold")
        #expect(resolve(.init(family: "SampleSans")) == nil)
    }

    @Test("withSymbolicTraits on plain faces: the face with exactly those traits, nearest Regular or Bold")
    func plainTraits() {
        let change = { (name: String, bits: UInt32) -> String? in
            FontDescriptorResolution.request(.init(name: name), withSymbolicTraits: bits, in: catalog)?.name
        }
        #expect(change("SampleSans-Regular", 2) == "SampleSans-Bold")
        #expect(change("SampleSans-Bold", 0) == "SampleSans-Regular")
        #expect(change("SampleSans-Bold", 1) == "SampleSans-Italic")
        #expect(change("SampleSans-Regular", 3) == nil)
        #expect(change("SampleSans-Regular", 0x40) == nil)
    }
}
