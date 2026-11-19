import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

/// The open faces are kept to the most recently used, however many sizes a
/// game draws at (labels animating their scale, text drawn into bitmaps at
/// each screen scale).
@Suite("Face cache") struct FaceCacheTests {
    private static func library(limit: Int) throws -> FontLibrary {
        let library = FontLibrary()
        _ = try library.register(path: Fonts.directory + "/KoHo-Bold.ttf")
        library.faceLimit = limit
        return library
    }

    @Test("No more faces stay open than the limit, the newest kept")
    func bounded() throws {
        let library = try Self.library(limit: 4)
        for size in 10 ... 30 { _ = library.face(FontKey(name: "KoHo-Bold", size: CGFloat(size))) }
        #expect(library.openFaces == 4)
        let newest = library.face(FontKey(name: "KoHo-Bold", size: 30))
        #expect(newest != nil && newest === library.face(FontKey(name: "KoHo-Bold", size: 30)))
    }

    @Test("A face used again moves to the back of the queue and survives")
    func recentlyUsedSurvives() throws {
        let library = try Self.library(limit: 3)
        let first = library.face(FontKey(name: "KoHo-Bold", size: 12))
        _ = library.face(FontKey(name: "KoHo-Bold", size: 13))
        _ = library.face(FontKey(name: "KoHo-Bold", size: 12))     // used again
        _ = library.face(FontKey(name: "KoHo-Bold", size: 14))
        _ = library.face(FontKey(name: "KoHo-Bold", size: 15))     // evicts 13, not 12
        #expect(library.face(FontKey(name: "KoHo-Bold", size: 12)) === first)
    }

    @Test("An evicted face is made again, measuring as before")
    func evictedIsRemade() throws {
        let library = try Self.library(limit: 1)
        let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
        let before = engine.measure("Level Select", font: FontKey(name: "KoHo-Bold", size: 20)).advance
        _ = library.face(FontKey(name: "KoHo-Bold", size: 21))
        engine.flush()
        #expect(engine.measure("Level Select", font: FontKey(name: "KoHo-Bold", size: 20)).advance == before)
        #expect(library.openFaces == 1)
    }

    @Test("Lowering the limit closes faces at once")
    func lowering() throws {
        let library = try Self.library(limit: 10)
        for size in 10 ... 15 { _ = library.face(FontKey(name: "KoHo-Bold", size: CGFloat(size))) }
        library.faceLimit = 2
        #expect(library.openFaces == 2)
    }

    /// FreeType's library lists every face opened on it, and opening or
    /// closing one edits that list: faces made and closed on many threads at
    /// once (each library evicting as it goes) must not corrupt it.
    @Test("Faces open and close on many threads at once")
    func concurrentOpenAndClose() {
        DispatchQueue.concurrentPerform(iterations: 16) { thread in
            guard let library = try? Self.library(limit: 1) else { return }
            let engine = TextEngine(library: library, atlas: GlyphAtlas(library: library))
            for step in 0 ..< 40 {
                let size = 10 + CGFloat((thread * 40 + step) % 200) / 8
                _ = engine.measure("Level \(step)", font: FontKey(name: "KoHo-Bold", size: size))
            }
        }
    }
}
