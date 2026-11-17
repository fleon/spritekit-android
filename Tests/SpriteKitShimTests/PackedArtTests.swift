import Foundation
import Testing
@testable import SpriteKitShim

/// The index `Tools/Art/xcassets-art.js` writes, read back through
/// `AssetIndex`. `Tools/Art/Fixtures/Packed` is the packer's own output for
/// the two fixture catalogs beside it (`node Tools/Art/check-xcassets-art.js`
/// holds it to the packer byte for byte), so this is the loader's half of
/// that contract: an asset catalog's names, point sizes and slicing come out
/// of `AssetIndex` and `SKTexture(imageNamed:)` as they do on Apple.
@Suite("Art packed from an asset catalog")
struct PackedArtTests {
    static let packed = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SpriteKitShimTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the runtime
        .appendingPathComponent("Tools/Art/Fixtures/Packed")

    static func index() throws -> AssetIndex {
        try AssetIndex(directory: packed)
    }

    @Test("Every image set loads under Xcode's name, a namespace folder's included")
    func names() throws {
        let index = try Self.index()
        #expect(index.names == ["Button", "Icons/Star", "Plain", "SystemSymbols/clock.fill", "Wide"])
        #expect(index.scale == 3)
    }

    @Test("Sizes are points: pixels over the scale each set was taken at")
    func sizes() throws {
        let index = try Self.index()
        // @3x, 12×9 px.
        #expect(index["Plain"]?.size == CGSize(width: 4, height: 3))
        // Single-scale, 10×10 px.
        #expect(index["Icons/Star"]?.size == CGSize(width: 10, height: 10))
        // @3x from a second catalog.
        #expect(index["SystemSymbols/clock.fill"]?.size == CGSize(width: 3, height: 3))
        // @2x only, 600×4 px, on a page of its own.
        let wide = try #require(index["Wide"])
        #expect(wide.size == CGSize(width: 300, height: 2))
        #expect(index.pages[wide.page].repeats)
        #expect(wide.textureRect == CGRect(x: 0, y: 0, width: 1, height: 1))

        for name in index.names {
            let texture = SKTexture(imageNamed: name, in: index)
            #expect(texture.size() == index[name]?.size, "\(name)")
        }
    }

    @Test("Xcode's slicing arrives as cap insets in points, over the cut image")
    func slicing() throws {
        let index = try Self.index()
        // 30×20 px @2x, insets 4, 6, 6, 8 px and a 2×2 px centre: actool
        // keeps 16×12 px of it.
        let button = try #require(index["Button"])
        #expect(button.capInsets == UIEdgeInsets(top: 2, left: 3, bottom: 3, right: 4))
        #expect(button.size == CGSize(width: 8, height: 6))
        #expect(button.rect.size == CGSize(width: 16, height: 12))
        #expect(button.contentInsets == nil)
        #expect(button.anchor == nil)
        #expect(index["Plain"]?.capInsets == nil)
    }

    @Test("Every page is beside the index, at the size the index says")
    func pages() throws {
        let index = try Self.index()
        #expect(index.pages.count == 2)
        for page in index.pages.indices {
            let url = try #require(index.url(ofPage: page))
            let size = UIImage.pngSize(try Data(contentsOf: url))
            #expect(size == index.pages[page].size, "\(index.pages[page].file)")
            #expect(index.pages[page].compressed == false)
        }
    }
}
