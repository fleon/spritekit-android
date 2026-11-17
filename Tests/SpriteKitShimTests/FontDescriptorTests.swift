import Foundation
import Testing
@testable import SpriteKitShim

// How a font descriptor's family and weight pick a face, as CoreText picks
// them on a Mac for two variable fonts with named instances from Thin (100)
// to Black (900), and from ExtraLight (200) to ExtraBold (800), registered
// with CTFontManagerRegisterFontsForURL (Google Fonts' Nunito and Dosis,
// called Sans and Rounded here):
//
//   family + weight trait          → PostScript name
//   Sans regular/medium/semibold → Sans-Regular/-Medium/-SemiBold
//   Sans bold/heavy/black        → Sans-Bold/-ExtraBold/-ExtraBold
//   family + wght variation        → that instance, whatever the trait
//   Sans 900, Rounded 600          → Sans-Black, Rounded-SemiBold

@Suite("Font descriptors")
struct FontDescriptorTests {
    private let registered: Set<String> = [
        "Sans", "Sans-ExtraLight", "Sans-Light", "Sans-Regular", "Sans-Medium", "Sans-SemiBold",
        "Sans-Bold", "Sans-ExtraBold", "Sans-Black",
        "Rounded", "Rounded-ExtraLight", "Rounded-Light", "Rounded-Regular", "Rounded-Medium", "Rounded-SemiBold",
        "Rounded-Bold", "Rounded-ExtraBold",
    ]

    private func name(_ family: String, trait: CGFloat) -> String {
        FontDescriptorResolution.name(
            family: family, weight: FontDescriptorResolution.openTypeWeight(for: trait)
        ) { registered.contains($0) }
    }

    @Test("A weight trait picks the instance CoreText does")
    func traits() {
        #expect(name("Sans", trait: 0) == "Sans-Regular")
        #expect(name("Sans", trait: 0.23) == "Sans-Medium")
        #expect(name("Sans", trait: 0.3) == "Sans-SemiBold")
        #expect(name("Sans", trait: 0.4) == "Sans-Bold")
        #expect(name("Sans", trait: 0.56) == "Sans-ExtraBold")
        #expect(name("Sans", trait: 0.62) == "Sans-ExtraBold")
        #expect(name("Rounded", trait: 0.4) == "Rounded-Bold")
        #expect(name("Rounded", trait: 0.62) == "Rounded-ExtraBold")
    }

    @Test("A wght variation picks its own instance")
    func variations() {
        #expect(FontDescriptorResolution.name(family: "Sans", weight: 900) { registered.contains($0) } == "Sans-Black")
        #expect(FontDescriptorResolution.name(family: "Rounded", weight: 600) { registered.contains($0) } == "Rounded-SemiBold")
    }

    @Test("An instance the text stack lacks falls to the nearest, then the family")
    func fallbacks() {
        // Rounded stops at 800.
        #expect(FontDescriptorResolution.name(family: "Rounded", weight: 900) { registered.contains($0) } == "Rounded-ExtraBold")
        #expect(FontDescriptorResolution.name(family: "Plain", weight: 400) { $0 == "Plain" } == "Plain")
    }
}
