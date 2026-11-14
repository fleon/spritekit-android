import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

@Suite("Baked textures")
struct BakedTexturesTests {
    /// Starry Sky's floor and the edge shade baked after it are both
    /// throwaway canvases, freed as each bake returns, so the second could
    /// land at the first's address. Keyed by that node, the edge shade's
    /// bake deleted the floor the sky still sampled.
    @Test("A bake from a canvas at a freed one's address keeps the first texture")
    func reusedAddress() {
        var baked = BakedTextures()
        let floor = SKTexture(color: .clear, size: CGSize(width: 4, height: 4))
        let shade = SKTexture(color: .clear, size: CGSize(width: 4, height: 4))
        baked.add(floor, name: 7, width: 4, height: 4)
        #expect(baked.sweep().isEmpty)
        baked.add(shade, name: 8, width: 4, height: 4)
        #expect(baked.sweep().isEmpty, "both are still held")
        #expect(baked.size(of: 7)?.width == 4)
        withExtendedLifetime((floor, shade)) {}
    }

    @Test("A texture the game lets go of is deleted at the next sweep")
    func released() {
        var baked = BakedTextures()
        let kept = SKTexture(color: .clear, size: CGSize(width: 2, height: 2))
        do {
            let dropped = SKTexture(color: .clear, size: CGSize(width: 2, height: 2))
            baked.add(dropped, name: 3, width: 2, height: 2)
        }
        baked.add(kept, name: 4, width: 2, height: 2)
        #expect(baked.sweep() == [3])
        #expect(baked.size(of: 3) == nil)
        #expect(baked.count == 1)
        #expect(baked.removeAll() == [4])
        withExtendedLifetime(kept) {}
    }
}

@Suite("Premultiplied alpha")
struct PremultiplyTests {
    /// An edge pixel of `RigFarmB.png`: the chick's yellow at full strength
    /// where it's a quarter covered, as a PNG keeps it.
    @Test("A straight edge pixel is scaled by its alpha; opaque and clear ones keep theirs")
    func scales() {
        let straight = Data([247, 206, 37, 62, 10, 20, 30, 255, 200, 100, 50, 0])
        let out = [UInt8](Premultiply.rgba(straight))
        #expect(Array(out[0 ..< 4]) == [60, 50, 9, 62])
        #expect(Array(out[4 ..< 8]) == [10, 20, 30, 255])
        #expect(Array(out[8 ..< 12]) == [0, 0, 0, 0])
    }
}
