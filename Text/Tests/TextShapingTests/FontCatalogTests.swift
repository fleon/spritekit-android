#if canImport(CoreText)
import CoreText
import Foundation
import SpriteKitShim
import Testing
@testable import TextShaping

// The text stack's font catalog, which Android's CoreText calls stand on
// (`CTFontManagerCreateFontDescriptorsFromURL`,
// `CTFontManagerRegisterFontURLs`, `UIFont(name:size:)`), measured against
// CoreText itself on the Mac, on the Mac's own font files: a plain one, a
// variable one with named instances, and SF, a variable one with hundreds.

private let geneva = "/System/Library/Fonts/Geneva.ttf"
private let newYork = "/System/Library/Fonts/NewYork.ttf"
private let sf = "/System/Library/Fonts/SFNS.ttf"

/// What CoreText lists for a file: each descriptor's PostScript name.
private func coreTextFaces(_ path: String) -> [String]? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor] else {
        return nil
    }
    return descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 0, nil)) as String }
}

/// How many errors CoreText reports registering `path` (process scope).
private func coreTextRegistrationErrors(_ path: String) -> Int {
    var count = -1
    let done = DispatchSemaphore(value: 0)
    CTFontManagerRegisterFontURLs([URL(fileURLWithPath: path)] as CFArray, .process, true) { errors, finished in
        if finished {
            count = CFArrayGetCount(errors)
            done.signal()
        }
        return true
    }
    done.wait()
    return count
}

@Suite("Font catalog against CoreText", .serialized)
struct FontCatalogTests {
    @Test("A file's faces are CoreText's descriptors: one for a plain file, a named instance each for a variable one", arguments: [geneva, newYork, sf])
    func faces(_ path: String) throws {
        let apple = try #require(coreTextFaces(path))
        #expect(try FontLibrary.faces(ofFontAt: path) == apple)
        let engine = TextEngine(library: FontLibrary(), atlas: .shared)
        #expect(engine.faceNames(inFontAt: path) == apple)
    }

    @Test("A file that isn't there, or isn't a font, has no faces, as CoreText's answer is nil")
    func notAFont() throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-font-\(UUID()).ttf")
        try Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        for path in ["/nonexistent.ttf", text.path] {
            #expect(coreTextFaces(path) == nil)
            let engine = TextEngine(library: FontLibrary(), atlas: .shared)
            #expect(engine.faceNames(inFontAt: path) == nil)
            #expect(engine.registerFont(at: path) == .unreadable)
        }
    }

    @Test("Registering makes a file's faces drawable; registering it again is an error, as on Apple")
    func registration() throws {
        // A copy, so CoreText sees a file it has never registered. New York,
        // which no other suite asks for by name: a second copy of a face
        // registered for the process changes what its name resolves to in
        // the AppKit and SpriteKit parity suites running alongside. It is
        // unregistered again before the copy goes.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("NewYork-\(UUID()).ttf")
        try FileManager.default.copyItem(atPath: newYork, toPath: copy.path)
        defer {
            CTFontManagerUnregisterFontsForURL(copy as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: copy)
        }

        let engine = TextEngine(library: FontLibrary(), atlas: .shared)
        let face = try #require(engine.faceNames(inFontAt: copy.path)?.first)
        #expect(!engine.hasFace(named: face))

        #expect(coreTextRegistrationErrors(copy.path) == 0)
        #expect(engine.registerFont(at: copy.path) == .registered)
        #expect(engine.hasFace(named: face))

        #expect(coreTextRegistrationErrors(copy.path) == 1)
        #expect(engine.registerFont(at: copy.path) == .alreadyRegistered)
    }

    @Test("A file the shell registered at launch registers once for the game, without reading it again")
    func registeredAtLaunch() throws {
        let library = FontLibrary()
        let engine = TextEngine(library: library, atlas: .shared)
        let data = try Data(contentsOf: URL(fileURLWithPath: geneva))
        try library.register(data: data, name: "Geneva")
        #expect(engine.faceNames(inFontAt: "/somewhere/else/Geneva.ttf") == coreTextFaces(geneva))
        #expect(engine.registerFont(at: "/somewhere/else/Geneva.ttf") == .registered)
        #expect(engine.registerFont(at: "/somewhere/else/Geneva.ttf") == .alreadyRegistered)
    }

    @Test("Roboto's files a weight become the system font's faces when there is no variable one")
    func systemFaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("system-fonts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Any static face stands in for Roboto-Regular here: what is
        // measured is which files are read.
        try FileManager.default.copyItem(atPath: geneva, toPath: directory.appendingPathComponent("Roboto-Regular.ttf").path)
        try FileManager.default.copyItem(atPath: geneva, toPath: directory.appendingPathComponent("Roboto-Bold.ttf").path)
        let engine = TextEngine(library: FontLibrary(), atlas: .shared)
        #expect(engine.registerSystemFonts(in: directory.path) == ["Geneva", "Geneva"])
        #expect(engine.systemFaceNames.count == 2)

        let none = TextEngine(library: FontLibrary(), atlas: .shared)
        #expect(none.registerSystemFonts(in: "/nonexistent").isEmpty)
    }
}
#endif
