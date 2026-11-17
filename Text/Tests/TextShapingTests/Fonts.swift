import CTextShaping
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// The test fonts: open-licensed files kept with the tests
/// (`Text/Tests/Fixtures/Fonts`, each with its licence), and for Chinese,
/// Japanese and Korean the Mac's own faces, read where macOS keeps them
/// (these tests run on the Mac).
///
/// - Montserrat: a variable Latin font whose named instances are its weights
///   (`Montserrat-Black`, `-ExtraBold`, `-SemiBold`…), the kind of file a
///   game asks for by instance name.
/// - KoHo Bold: Thai, the script where FreeType alone is wrong (marks,
///   SARA AM, descenders) and HarfBuzz has to be right.
/// - Hiragino Sans GB: Han and kana; Apple SD Gothic Neo: Hangul.
enum Fonts {
    static let directory: String = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TextShapingTests
        url.deleteLastPathComponent()   // Tests
        return url.appendingPathComponent("Fixtures/Fonts").path
    }()

    static let hiragino = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    static let appleSDGothic = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
    /// Whether the Mac's Han and Hangul faces are there; the tests that
    /// need them are skipped where they aren't.
    static let hasCJK = FileManager.default.fileExists(atPath: hiragino)
        && FileManager.default.fileExists(atPath: appleSDGothic)

    /// One engine for the whole run, every size sharing each file's bytes.
    static let engine: TextEngine = {
        let library = FontLibrary()
        let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        for file in ["Montserrat", "KoHo-Bold"] {
            _ = try? library.register(path: directory + "/" + file + ".ttf")
        }
        for path in [hiragino, appleSDGothic] {
            _ = try? library.register(path: path)
        }
        engine.install()
        return engine
    }()

    /// A named instance of a variable font, at its heaviest.
    static func display(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "Montserrat-Black", size: size)
    }

    /// KoHo Bold, for Thai.
    static func koHo(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "KoHo-Bold", size: size)
    }

    /// Han and kana (Hiragino Sans GB's first face).
    static func han(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "HiraginoSansGB-W3", size: size)
    }

    /// Hangul (Apple SD Gothic Neo's first face).
    static func hangul(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "AppleSDGothicNeo-Regular", size: size)
    }

    /// What FreeType alone would do: one glyph per codepoint, in codepoint
    /// order, each with its own advance. This is the thing the Thai tests
    /// are measured against.
    static func naive(_ text: String, font: FontKey) -> (glyphs: [UInt32], advance: CGFloat) {
        guard let face = engine.library.face(font), let ft = face.ftFace else { return ([], 0) }
        var glyphs: [UInt32] = []
        var advance: CGFloat = 0
        for scalar in text.unicodeScalars {
            let glyph = FT_Get_Char_Index(ft, FT_ULong(scalar.value))
            glyphs.append(glyph)
            if FT_Load_Glyph(ft, glyph, FaceHandle.loadFlags) == FT_Err_Ok,
               let slot = ft.pointee.glyph {
                advance += CGFloat(slot.pointee.advance.x) / 64
            }
        }
        return (glyphs, advance)
    }
}
