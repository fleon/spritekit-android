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
        // Geneva too, a face with a line gap, which the fixtures lack.
        for path in [hiragino, appleSDGothic, "/System/Library/Fonts/Geneva.ttf"] {
            _ = try? library.register(path: path)
        }
        #if canImport(CoreText)
        // Strikes' PNGs (emoji) decode as the shell's decoder decodes them.
        UIImage.decoder = { ImageIODecoder.decode($0) }
        // Characters the test faces lack fall back as Core Text's do.
        _ = CoreTextFallback.registered
        engine.fallback = CoreTextFallback(library: library)
        #endif
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

#if canImport(CoreText)
import CoreText
import ImageIO

/// PNG to premultiplied RGBA, top row first, as `UIImage.decoder` hands
/// images over on a device.
enum ImageIODecoder {
    static func decode(_ data: Data) -> RasterImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RasterImage(width: width, height: height, pixels: pixels)
    }
}

/// Core Text's own fallback (`CTFontCreateForString`) as the provider, so
/// the tests compare fallback text with Apple's on the same faces: the
/// face it picks, found by PostScript name in its file.
final class CoreTextFallback: FontFallbackProvider, @unchecked Sendable {
    private let library: FontLibrary
    private let lock = NSLock()
    private var indices: [String: Int] = [:]
    static let registered: Bool = {
        for file in ["KoHo-Bold", "Montserrat"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: Fonts.directory + "/" + file + ".ttf") as CFURL, .process, nil)
        }
        return true
    }()

    init(library: FontLibrary) {
        self.library = library
    }

    func face(for character: Character, font: FontKey, weight: Int) -> FallbackFace? {
        _ = Self.registered
        // One query at a time: Core Text's font registry, asked cold from
        // every test thread at once, can stall them all.
        lock.lock()
        defer { lock.unlock() }
        let primary = CTFontCreateWithName(font.name as CFString, font.size, nil)
        let string = String(character) as CFString
        // Japanese, so Han falls back to Hiragino: FreeType can't read the
        // Mac's PingFang (a private format).
        let picked = CTFontCreateForStringWithLanguage(primary, string, CFRange(location: 0, length: CFStringGetLength(string)), "ja" as CFString)
        let name = CTFontCopyPostScriptName(picked) as String
        guard name != CTFontCopyPostScriptName(primary) as String,
              let url = CTFontCopyAttribute(picked, kCTFontURLAttribute) as? URL else { return nil }
        let path = url.path
        // A variable face's axes as Core Text set them, by tag.
        var variations: [String: Double] = [:]
        for (key, value) in (CTFontCopyVariation(picked) as? [NSNumber: NSNumber]) ?? [:] {
            let tag = key.uint32Value
            let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: tag >> $0) }, encoding: .ascii) ?? ""
            variations[name] = value.doubleValue
        }
        let key = path + "#" + name
        let index = { () -> Int? in
            if let known = indices[key] { return known }
            guard let file = library.file(atPath: path) else { return nil }
            for index in 0 ..< max(1, file.faceCount) {
                guard let probe = try? FaceHandle(file: file, size: 16, instance: nil, index: index) else { continue }
                // A variable collection's faces go by their default instance's name.
                let family = { (name: String) in name.split(separator: "-").first }
                if probe.postScriptName == name || !variations.isEmpty && probe.postScriptName.map(family) == family(name) {
                    indices[key] = index
                    return index
                }
            }
            return nil
        }()
        return index.map { FallbackFace(path: path, index: $0, variations: variations) }
    }
}
#endif
