import CTextShaping
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// The game's real font files, found from this file's own path, so these
/// tests measure what ships rather than a stand-in.
enum Fonts {
    static let directory: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Assets/Fonts").path
    }()

    /// One engine for the whole run: registering Chiron GoRound TC reads a
    /// 50 MB variable font, and every size shares those bytes.
    static let engine: TextEngine = {
        let library = FontLibrary()
        let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        for file in ["ChironGoRoundTC-Variable", "KoHo-Bold", "Montserrat"] {
            _ = try? library.register(path: directory + "/" + file + ".ttf")
        }
        engine.install()
        return engine
    }()

    /// Chiron at the weight the game's buttons use.
    static func chiron(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "ChironGoRoundTC-Black", size: size)
    }

    /// KoHo Bold, which is all the Thai the game ever draws.
    static func koHo(_ size: CGFloat = 32) -> FontKey {
        _ = engine
        return FontKey(name: "KoHo-Bold", size: size)
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
