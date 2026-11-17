import Foundation
import Testing
@testable import SpriteKitShim

// How a font descriptor's family and weight pick a face, as CoreText picks
// them on a Mac for the games' own variable fonts (Nunito-Variable.ttf,
// Dosis-Variable.ttf, registered with CTFontManagerRegisterFontsForURL):
//
//   family + weight trait          → PostScript name
//   Nunito regular/medium/semibold → Nunito-Regular/-Medium/-SemiBold
//   Nunito bold/heavy/black        → Nunito-Bold/-ExtraBold/-ExtraBold
//   family + wght variation        → that instance, whatever the trait
//   Nunito 900, Dosis 600          → Nunito-Black, Dosis-SemiBold

@Suite("Font descriptors")
struct FontDescriptorTests {
    private let registered: Set<String> = [
        "Nunito", "Nunito-ExtraLight", "Nunito-Light", "Nunito-Regular", "Nunito-Medium", "Nunito-SemiBold",
        "Nunito-Bold", "Nunito-ExtraBold", "Nunito-Black",
        "Dosis", "Dosis-ExtraLight", "Dosis-Light", "Dosis-Regular", "Dosis-Medium", "Dosis-SemiBold",
        "Dosis-Bold", "Dosis-ExtraBold",
    ]

    private func name(_ family: String, trait: CGFloat) -> String {
        FontDescriptorResolution.name(
            family: family, weight: FontDescriptorResolution.openTypeWeight(for: trait)
        ) { registered.contains($0) }
    }

    @Test("A weight trait picks the instance CoreText does")
    func traits() {
        #expect(name("Nunito", trait: 0) == "Nunito-Regular")
        #expect(name("Nunito", trait: 0.23) == "Nunito-Medium")
        #expect(name("Nunito", trait: 0.3) == "Nunito-SemiBold")
        #expect(name("Nunito", trait: 0.4) == "Nunito-Bold")
        #expect(name("Nunito", trait: 0.56) == "Nunito-ExtraBold")
        #expect(name("Nunito", trait: 0.62) == "Nunito-ExtraBold")
        #expect(name("Dosis", trait: 0.4) == "Dosis-Bold")
        #expect(name("Dosis", trait: 0.62) == "Dosis-ExtraBold")
    }

    @Test("A wght variation picks its own instance")
    func variations() {
        #expect(FontDescriptorResolution.name(family: "Nunito", weight: 900) { registered.contains($0) } == "Nunito-Black")
        #expect(FontDescriptorResolution.name(family: "Dosis", weight: 600) { registered.contains($0) } == "Dosis-SemiBold")
    }

    @Test("An instance the text stack lacks falls to the nearest, then the family")
    func fallbacks() {
        // Dosis stops at 800.
        #expect(FontDescriptorResolution.name(family: "Dosis", weight: 900) { registered.contains($0) } == "Dosis-ExtraBold")
        #expect(FontDescriptorResolution.name(family: "Montserrat", weight: 400) { $0 == "Montserrat" } == "Montserrat")
    }
}
