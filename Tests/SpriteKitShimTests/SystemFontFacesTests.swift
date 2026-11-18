import Foundation
import Testing
@testable import SpriteKitShim

// Which of the device's faces `UIFont.systemFont(ofSize:weight:)` draws
// with: Roboto's named instances on Android 12 and later, a file a weight
// before that.

/// Android 16's /system/fonts/Roboto-Regular.ttf, as CoreText lists its
/// named instances (upright, italic and condensed).
private let roboto = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]
    .flatMap { ["Roboto-\($0)", "Roboto-\($0)Italic", "Roboto-Condensed\($0)"] } + ["Roboto-Italic"]

/// UIKit's weights' raw values, lightest first.
private let weights: [(name: String, raw: CGFloat)] = [
    ("ultraLight", -0.8), ("thin", -0.6), ("light", -0.4), ("regular", 0), ("medium", 0.23),
    ("semibold", 0.3), ("bold", 0.4), ("heavy", 0.56), ("black", 0.62),
]

@Suite("System font faces")
struct SystemFontFacesTests {
    @Test("Each UIKit weight draws in the Roboto instance of SF's weight class, upright")
    func variableRoboto() {
        let picked = weights.map { SystemFontFaces.face(forWeight: $0.raw, among: roboto) }
        #expect(picked == [
            "Roboto-Thin", "Roboto-ExtraLight", "Roboto-Light", "Roboto-Regular", "Roboto-Medium",
            "Roboto-SemiBold", "Roboto-Bold", "Roboto-ExtraBold", "Roboto-Black",
        ])
    }

    @Test("With a file a weight, the nearest one, heavier above regular and lighter below")
    func staticRoboto() {
        let files = ["Roboto-Regular", "Roboto-Thin", "Roboto-Light", "Roboto-Medium", "Roboto-Bold", "Roboto-Black"]
        let picked = weights.map { SystemFontFaces.face(forWeight: $0.raw, among: files) }
        #expect(picked == [
            "Roboto-Thin", "Roboto-Thin", "Roboto-Light", "Roboto-Regular", "Roboto-Medium",
            "Roboto-Bold", "Roboto-Bold", "Roboto-Black", "Roboto-Black",
        ])
    }

    @Test("A weight between UIKit's goes to the nearest of them")
    func between() {
        #expect(SystemFontFacesTests.face(0.35) == "Roboto-SemiBold")
        #expect(SystemFontFacesTests.face(0.1) == "Roboto-Regular")
        #expect(SystemFontFacesTests.face(-1) == "Roboto-Thin")
        #expect(SystemFontFacesTests.face(1) == "Roboto-Black")
    }

    @Test("No face that says its weight, no system face")
    func none() {
        #expect(SystemFontFaces.face(forWeight: 0, among: []) == nil)
        #expect(SystemFontFaces.face(forWeight: 0, among: ["Roboto", "Roboto-CondensedBold"]) == nil)
    }

    private static func face(_ raw: CGFloat) -> String? {
        SystemFontFaces.face(forWeight: raw, among: roboto)
    }
}
