import Foundation
import Testing
@testable import SpriteKitShim

// The one piece of the shim that works by overload resolution rather than by
// being the only thing in scope, so it is the one worth pinning down.
// Serialized because the provider is one global: these would otherwise
// swap it out from under each other.
@Suite("Bundle resources", .serialized)
struct BundleResourcesTests {
    /// A game asks `Bundle.main.url(forResource: "RigHero", withExtension: "json")`
    /// with two plain `String`s. Foundation's takes `String?`, so this one —
    /// which takes `String` — is the better match and wins. If Swift ever
    /// stopped preferring it, the game would quietly read nothing on Android.
    @Test("A plain-String call reaches the shim's overload, not Foundation's")
    func overloadWins() {
        var asked: [String] = []
        BundleResources.provider = { name, ext in
            asked.append("\(name).\(ext)")
            return URL(fileURLWithPath: "/rigs/\(name).\(ext)")
        }
        defer { BundleResources.provider = nil }

        let url = Bundle.main.url(forResource: "RigHero", withExtension: "json")
        #expect(asked == ["RigHero.json"])
        #expect(url?.path == "/rigs/RigHero.json")
    }

    @Test("With no provider, it answers as Foundation would")
    func fallsThrough() {
        BundleResources.provider = nil
        // Nothing of this name anywhere, and — the real point — no recursion
        // between the overload and the one it falls through to.
        #expect(Bundle.main.url(forResource: "NoSuchThing", withExtension: "qqq") == nil)
    }

    @Test("A provider that does not know an asset falls through too")
    func providerMayDecline() {
        BundleResources.provider = { name, _ in
            name.hasPrefix("Rig") ? URL(fileURLWithPath: "/rigs/\(name)") : nil
        }
        defer { BundleResources.provider = nil }

        #expect(Bundle.main.url(forResource: "RigFaces", withExtension: "png") != nil)
        #expect(Bundle.main.url(forResource: "Theme", withExtension: "m4a") == nil)
    }

    @Test("A PNG's size is read from its header without decoding it")
    func pngHeader() {
        // An 8x5 greyscale PNG header: signature, length, IHDR, w, h.
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        bytes += [0, 0, 0, 8, 0, 0, 0, 5]
        #expect(UIImage.pngSize(Data(bytes)) == CGSize(width: 8, height: 5))

        // Not a PNG, and a truncated one.
        #expect(UIImage.pngSize(Data(repeating: 0, count: 24)) == nil)
        #expect(UIImage.pngSize(Data(bytes.prefix(20))) == nil)
    }
}
